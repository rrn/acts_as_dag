# options[:link_conditions] used to apply constraint on the links and descendants tables. Default assumes links for all classes are in the same table, similarly for descendants. Can be cleared to allow setup of individual tables for each acts_as_dag class's links and descendants
module ActsAsDAG
  module ActMethod
    def acts_as_dag(options = {})
      class_attribute :acts_as_dag_options
      options.assert_valid_keys :allow_root_and_parent, :link_class, :descendant_class, :link_table, :descendant_table, :link_conditions
      options.reverse_merge!(
        :allow_root_and_parent => false,                              # If false, record is unlinked from root when it gains a parent
        :link_class            => "#{self.name}Link",
        :link_table            => "acts_as_dag_links",
        :descendant_class      => "#{self.name}Descendant",
        :descendant_table      => "acts_as_dag_descendants",
        :link_conditions       => {:category_type => self.name})
      self.acts_as_dag_options = options

      # Create Link and Descendant Classes
      class_eval <<-RUBY
        class ::#{options[:link_class]} < ActsAsDAG::AbstractLink
          self.table_name = '#{options[:link_table]}'
          belongs_to :parent, :class_name => '#{self.name}', :foreign_key => :parent_id, :inverse_of => :child_links
          belongs_to :child, :class_name => '#{self.name}', :foreign_key => :child_id, :inverse_of => :parent_links

          after_save Proc.new {|link| HelperMethods.update_transitive_closure_for_new_link(link) }
          after_destroy Proc.new {|link| HelperMethods.update_transitive_closure_for_destroyed_link(link) }

          def node_class; #{self.name} end
        end

        class ::#{options[:descendant_class]} < ActsAsDAG::AbstractDescendant
          self.table_name = '#{options[:descendant_table]}'
          belongs_to :ancestor, :class_name => '#{self.name}', :foreign_key => :ancestor_id
          belongs_to :descendant, :class_name => '#{self.name}', :foreign_key => :descendant_id

          def node_class; #{self.name} end
        end

        def self.link_class
          ::#{options[:link_class]}
        end

        def self.descendant_class
          ::#{options[:descendant_class]}
        end
      RUBY

      # Returns a relation scoping to only link table entries that match the link conditions
      def self.link_table_entries
        link_class.where(acts_as_dag_options[:link_conditions])
      end

      # Returns a relation scoping to only descendant table entries table entries that match the link conditions
      def self.descendant_table_entries
        descendant_class.where(acts_as_dag_options[:link_conditions])
      end

      # Rails 4.0.0 currently ignores the order clause when eager loading, so results may not be returned in the correct order
      # Ancestors must always be returned in order of most distant to least, e.g. D's ancestors are [A, B, C] or [A, C, B]
      # Descendants must always be returned in order of least distant to most, e.g. A's descendants are [B, C, D] or [C, B, D]
      #   A
      #  / \
      # B   C
      #  \ /
      #   D
      #
      has_many :ancestor_links,   -> { where(options[:link_conditions]).where("ancestor_id != descendant_id").order("distance DESC") }, :class_name => descendant_class.name, :foreign_key => 'descendant_id'
      has_many :descendant_links, -> { where(options[:link_conditions]).where("descendant_id != ancestor_id").order("distance ASC") }, :class_name => descendant_class.name, :foreign_key => 'ancestor_id'

      has_many :path_links,       -> { where(options[:link_conditions]).order("distance DESC") }, :class_name => descendant_class.name, :foreign_key => 'descendant_id', :dependent => :delete_all
      has_many :subtree_links,    -> { where(options[:link_conditions]).order("distance ASC") }, :class_name => descendant_class.name, :foreign_key => 'ancestor_id', :dependent => :delete_all

      has_many :ancestors,        :through => :ancestor_links, :source => :ancestor
      has_many :descendants,      :through => :descendant_links, :source => :descendant

      has_many :path,             :through => :path_links, :source => :ancestor
      has_many :subtree,          :through => :subtree_links, :source => :descendant

      has_many :parent_links,     -> { where options[:link_conditions] }, :class_name => link_class.name, :foreign_key => 'child_id', :dependent => :delete_all, :inverse_of => :child
      has_many :child_links,      -> { where options[:link_conditions] }, :class_name => link_class.name, :foreign_key => 'parent_id', :dependent => :delete_all, :inverse_of => :parent

      has_many :parents,          :through => :parent_links, :source => :parent do
        def <<(other)
          if other
            super
          else
            proxy_association.owner.make_root
          end
        end
      end
      has_many :children,         :through => :child_links, :source => :child

      # NOTE: Use select to prevent ActiveRecord::ReadOnlyRecord if the returned records are modified
      scope :roots,               -> { joins(:parent_links).where(link_class.table_name => {:parent_id => nil}) }
      scope :leaves,              -> { joins("LEFT OUTER JOIN #{link_class.table_name} ON #{table_name}.id = parent_id").where(link_class.table_name => {:child_id => nil}).distinct }
      scope :children,            -> { joins(:parent_links).where.not(link_class.table_name => {:parent_id => nil}).distinct }
      scope :parent_records,      -> { joins(:child_links).where.not(link_class.table_name => {:child_id => nil}).distinct }

      scope :ancestors_of,        ->(record) { joins(:descendant_links).where(descendant_class.table_name => { :descendant_id => record }).distinct }
      scope :descendants_of,      ->(record) { joins(:ancestor_links).where(descendant_class.table_name => { :ancestor_id => record }).distinct }
      scope :path_of,             ->(record) { joins(:subtree_links).where(descendant_class.table_name => { :descendant_id => record }).distinct }
      scope :subtree_of,          ->(record) { joins(:path_links).where(descendant_class.table_name => { :ancestor_id => record }).distinct }

      after_create :initialize_dag

      extend ActsAsDAG::ClassMethods
      include ActsAsDAG::InstanceMethods
      extend ActsAsDAG::Deprecated::ClassMethods
      include ActsAsDAG::Deprecated::InstanceMethods
    end
  end

  module ClassMethods
    def acts_like_dag?
      true
    end

    # Remove all hierarchy information for this category
    # Can pass a list of categories to reset
    def reset_hierarchy(categories_to_reset = self.all)
      ids = categories_to_reset.collect(&:id)

      link_table_entries.where("parent_id IN (?) OR child_id IN (?)", ids, ids).delete_all

      descendant_table_entries.where("descendant_id IN (?) OR ancestor_id IN (?)", ids, ids).delete_all

      categories_to_reset.each do |category|
        category.send :initialize_dag
      end
    end
  end

  module InstanceMethods
    # NOTE: Parents that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    def parents=(parents)
      (self.parents - parents).each do |parent_to_remove|
        remove_parent(parent_to_remove)
      end

      parents_except_root = ActsAsDAG::HelperMethods.except_root(parents)
      parents_contained_root = parents != parents_except_root

      super parents_except_root

      if self.parents.empty? && !acts_as_dag_options[:allow_root_and_parent]
        make_root
      elsif parents_contained_root
        make_root
      else
        unroot
      end
    end

    # NOTE: Children that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    def children=(children)
      (self.children - children).each do |child_to_remove|
        remove_child(child_to_remove)
      end
      super
    end

    # Returns true if the category's children include *self*
    def child_of?(category, options = {})
      category.children.exists?(id)
    end

    # Returns true if the category's parents include *self*
    def parent_of?(category, options = {})
      category.parents.exists?(id)
    end

    # Returns true if the category's descendants include *self*
    def descendant_of?(category, options = {})
      category.descendants.exists?(id)
    end

    # Returns true if the category's descendants include *self*
    def ancestor_of?(category, options = {})
      category.ancestors.exists?(id)
    end

    # Returns the class used for links
    def link_class
      self.class.link_class
    end

    # Returns the class used for descendants
    def descendant_class
      self.class.descendant_class
    end

    # Returns an array of ancestors and descendants
    def lineage
      lineage_links = self.class.descendant_table_entries
                                  .select("(CASE ancestor_id WHEN #{id} THEN descendant_id ELSE ancestor_id END) AS id, ancestor_id, descendant_id, distance")
                                  .where('ancestor_id = :id OR descendant_id = :id', :id => id)
                                  .where('ancestor_id != descendant_id')                        # Don't include self

      self.class.joins("JOIN (#{lineage_links.to_sql}) lineage_links ON #{self.class.table_name}.id = lineage_links.id").order("CASE ancestor_id WHEN #{id} THEN distance ELSE -distance END") # Ensure the links are orders furthest ancestor to furthest descendant
    end

    def distance_to(other)
      self.class.descendant_table_entries
        .where(:ancestor_id => [self.id, other.id], :descendant_id => [self.id, other.id])
        .where('ancestor_id != descendant_id')
        .minimum(:distance)
    end

    # Returns true if this record is a root node
    def root?
      self.class.roots.exists?(self.id)
    end

    def leaf?
      children.empty?
    end

    def make_root
      unless acts_as_dag_options[:allow_root_and_parent]
        parents.each do |parent|
          remove_parent(parent)
        end
      end

      add_parent(nil)
    end

    def unroot
      remove_parent(nil)
    end

    # Adds a category as a parent of this category (self)
    def add_parent(*parents)
      parents.flatten.each do |parent|
        ActsAsDAG::HelperMethods.link(parent, self)
      end
    end

    # Adds a category as a child of this category (self)
    def add_child(*children)
      children.flatten.each do |child|
        ActsAsDAG::HelperMethods.link(self, child)
      end
    end

    # Removes a category as a child of this category (self)
    # Returns the child
    def remove_child(child)
      ActsAsDAG::HelperMethods.unlink(self, child)
      return child
    end

    # Removes a category as a parent of this category (self)
    # Returns the parent
    def remove_parent(parent)
      ActsAsDAG::HelperMethods.unlink(parent, self)
      return parent
    end

    private

    # CALLBACKS

    def initialize_dag
      subtree_links.first_or_create!(:descendant_id => self.id, :distance => 0) # Self Descendant
      parent_links.first_or_create!(:parent_id => nil) # Root link
    end
  end

  module HelperMethods
    # Returns only records that aren't the root node (nil)
    def self.except_root(records)
      records.reject {|p| p.nil? }
    end

    # creates a single link in the given link_class's link table between parent and
    # child object ids and creates the appropriate entries in the descendant table
    def self.link(parent, child)
      # Sanity check
      raise "Parent has no ID" if parent && parent.try(:id).nil?
      raise "Child has no ID" if child.id.nil?
      raise "Parent and child must be the same class" if parent && parent.class != child.class

      klass = child.class

      # Return if the link already exists because we can assume that the proper descendants already exist too
      return if klass.link_table_entries.where(:parent_id => parent.try(:id), :child_id => child.id).exists?

      # Create a new parent-child link
      klass.link_table_entries.create!(:parent_id => parent.try(:id), :child_id => child.id)

      # If we have been passed a parent, find and destroy any existing links from nil (root) to the child as it can no longer be a top-level node
      unlink(nil, child) if parent && !child.class.acts_as_dag_options[:allow_root_and_parent]

      parent.children.reset if parent && parent.persisted?
      child.parents.reset if child.persisted?
    end

    def self.update_transitive_closure_for_new_link(new_link)
      klass = new_link.node_class

      # If we're passing :parents or :children to a new record as part of #create, transitive closure on the nested records will
      # be updated before the new record's after save calls :initialize_dag. We ensure it's been initalized before we start querying
      # its descendant_table or it won't appear as an ancestor or descendant until too late.
      new_link.parent.send(:initialize_dag) if new_link.parent && new_link.parent.saved_change_to_id?
      new_link.child.send(:initialize_dag) if new_link.child && new_link.child.saved_change_to_id?

      # FIXME: There is some bug that causes link to set the association, but not the foreign key when multiple parents are assigned simultaneously during create
      new_link.child_id = new_link.child.id if new_link.child

      # The parent and all its ancestors need to be added as ancestors of the child
      # The child and all its descendants need to be added as descendants of the parent
      ancestor_ids_and_distance = klass.descendant_table_entries.where(:descendant_id => new_link.parent_id).pluck(:ancestor_id, :distance) # (totem => totem pole), (totem_pole => totem_pole)
      descendant_ids_and_distance = klass.descendant_table_entries.where(:ancestor_id => new_link.child_id).pluck(:descendant_id, :distance) # (totem pole model => totem pole model)

      ancestor_ids_and_distance.each do |ancestor_id, ancestor_distance|
        descendant_ids_and_distance.each do |descendant_id, descendant_distance|
          klass.descendant_table_entries.find_or_create_by!(:ancestor_id => ancestor_id, :descendant_id => descendant_id, :distance => ancestor_distance + descendant_distance + 1)
        end
      end
    end

    # breaks a single link in the given hierarchy_link_table between parent and
    # child object id. Updates the appropriate Descendants table entries
    def self.unlink(parent, child)
      # Raise an exception if there is no child
      raise "Child cannot be nil when deleting a category_link" unless child

      klass = child.class

      # delete the link if it exists
      klass.link_table_entries.where(:parent_id => parent.try(:id), :child_id => child.id).destroy_all
      parent.children.reset if parent && parent.persisted?
      child.parents.reset if child.persisted?
    end

    def self.update_transitive_closure_for_destroyed_link(destroyed_link)
      # We have unlinked C and D
      #                 A   F
      #                / \ /
      #               B   C
      #               |
      #               |   D
      #                \ /
      #                 E
      #
      klass = destroyed_link.node_class
      parent = destroyed_link.parent
      child = destroyed_link.child

      # If the parent was nil, we don't need to update descendants because there are no descendants of nil
      return unless parent

      # Now destroy all affected subtree_links (ancestors of parent (C), descendants of child (D))
      klass.descendant_table_entries.where(:ancestor_id => parent.path_ids, :descendant_id => child.subtree_ids).delete_all

      # Now iterate through all ancestors of the subtree_links that were deleted and pick only those that have no parents, namely (A, D)
      # These will be the starting points for the recreation of descendant links
      starting_points = klass.find(parent.path_ids + child.subtree_ids).select {|node| node.parents.empty? || node.parents == [nil] }

      # POSSIBLE OPTIMIZATION: The two starting points may share descendants. We only need to process each node once, so if we could skip dups, that would be good
      starting_points.each{|node| rebuild_subtree_links(node)}
    end


    # Create a descendant link to iteself, then iterate through all children
    # We add this node to the ancestor array we received
    # Then we create a descendant link between it and all nodes in the array we were passed (nodes traversed between it and all its ancestors affected by the unlinking).
    # Then iterate to all children of the current node passing the ancestor array along
    def self.rebuild_subtree_links(current, path = [])
      indent = Array.new(path.size, "  ").join
      klass = current.class

      # Add current to the list of traversed nodes that we will pass to the children we decide to recurse to
      path << current

      # Create descendant links to each ancestor in the array (including itself)
      path.reverse.each_with_index do |record, index|
        klass.descendant_table_entries.find_or_create_by!(:ancestor_id => record.id, :descendant_id => current.id, :distance => index)
      end

      # Now check each child to see if it is a descendant, or if we need to recurse
      for child in current.children
        rebuild_subtree_links(child, path.dup)
      end
    end
  end

  # CLASSES (for providing hooks)
  class AbstractLink < ActiveRecord::Base
    self.abstract_class = true

    validate :not_self_referential

    def not_self_referential
      errors.add(:base, "Self referential links #{self.class} cannot be created.") if parent_id && parent_id == child_id
    end
  end

  class AbstractDescendant < ActiveRecord::Base
    self.abstract_class = true

    validates_presence_of :ancestor_id, :descendant_id
  end
end
