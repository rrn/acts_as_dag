# options[:link_conditions] used to apply constraint on the links and descendants tables. Default assumes links for all classes are in the same table, similarly for descendants. Can be cleared to allow setup of individual tables for each acts_as_dag class's links and descendants
module ActsAsDAG
  module ActMethod
    def acts_as_dag(options = {})
      class_attribute :acts_as_dag_options
      options.assert_valid_keys :link_class, :descendant_class, :link_table, :descendant_table, :link_conditions
      options.reverse_merge!(
        :link_class => "#{self.name}Link",
        :link_table => "acts_as_dag_links",
        :descendant_class => "#{self.name}Descendant",
        :descendant_table => "acts_as_dag_descendants",
        :link_conditions => {:category_type => self.name})
      self.acts_as_dag_options = options

      # Create Link and Descendant Classes
      class_eval <<-EOV
        class ::#{options[:link_class]} < ActsAsDAG::AbstractLink
          self.table_name = '#{options[:link_table]}'
          belongs_to :parent,     :class_name => '#{self.name}', :foreign_key => :parent_id, :inverse_of => :child_links
          belongs_to :child,      :class_name => '#{self.name}', :foreign_key => :child_id, :inverse_of => :parent_links

          after_save Proc.new {|link| HelperMethods.update_transitive_closure_for_new_link(link) }
          after_destroy Proc.new {|link| HelperMethods.update_transitive_closure_for_destroyed_link(link) }

          def node_class; #{self.name} end
        end

        class ::#{options[:descendant_class]} < ActsAsDAG::AbstractDescendant
          self.table_name = '#{options[:descendant_table]}'
          belongs_to :ancestor,   :class_name => '#{self.name}', :foreign_key => :ancestor_id
          belongs_to :descendant, :class_name => '#{self.name}', :foreign_key => :descendant_id

          def node_class; #{self.name} end
        end

        def self.link_class
          ::#{options[:link_class]}
        end

        def self.descendant_class
          ::#{options[:descendant_class]}
        end
      EOV

      # Returns a relation scoping to only link table entries that match the link conditions
      def self.link_table_entries
        link_class.where(acts_as_dag_options[:link_conditions])
      end

      # Returns a relation scoping to only descendant table entries table entries that match the link conditions
      def self.descendant_table_entries
        descendant_class.where(acts_as_dag_options[:link_conditions])
      end

      # Ancestors and descendants returned *include* self, e.g. A's descendants are [A,B,C,D]
      # Ancestors must always be returned in order of most distant to least
      # Descendants must always be returned in order of least distant to most
      # NOTE: Rails 4.0.0 currently ignores the order clause when eager loading, so results may not be returned in the correct order
      # NOTE: multiple instances of the same descendant/ancestor may be returned if there are multiple paths from ancestor to descendant
      #   A
      #  / \
      # B   C
      #  \ /
      #   D
      #
      has_many :ancestors,        lambda { where("#{descendant_class.table_name}.descendant_id != #{table_name}.id").order("#{descendant_class.table_name}.distance DESC") }, :through => :ancestor_links, :source => :ancestor
      has_many :descendants,      lambda { where("#{descendant_class.table_name}.ancestor_id != #{table_name}.id").order("#{descendant_class.table_name}.distance ASC") }, :through => :descendant_links, :source => :descendant

      has_many :path,             lambda { order("#{descendant_class.table_name}.distance DESC") }, :through => :ancestor_links, :source => :ancestor
      has_many :subtree,          lambda { order("#{descendant_class.table_name}.distance ASC") }, :through => :descendant_links, :source => :descendant

      has_many :ancestor_links,   lambda { where options[:link_conditions] }, :class_name => descendant_class, :foreign_key => 'descendant_id', :dependent => :delete_all
      has_many :descendant_links, lambda { where options[:link_conditions] }, :class_name => descendant_class, :foreign_key => 'ancestor_id', :dependent => :delete_all

      has_many :parents,          :through => :parent_links, :source => :parent
      has_many :children,         :through => :child_links, :source => :child
      has_many :parent_links,     lambda { where options[:link_conditions] }, :class_name => link_class, :foreign_key => 'child_id', :dependent => :delete_all, :inverse_of => :child
      has_many :child_links,      lambda { where options[:link_conditions] }, :class_name => link_class, :foreign_key => 'parent_id', :dependent => :delete_all, :inverse_of => :parent

      # NOTE: Use select to prevent ActiveRecord::ReadOnlyRecord if the returned records are modified
      scope :roots,               lambda { select("#{table_name}.*").joins(:parent_links).where(link_class.table_name => {:parent_id => nil}) }
      scope :children,            lambda { select("#{table_name}.*").joins(:parent_links).where.not(link_class.table_name => {:parent_id => nil}).uniq }
      scope :parent_records,      lambda { select("#{table_name}.*").joins(:child_links).where.not(link_class.table_name => {:child_id => nil}).uniq }

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
    # Returns true if this record is a root node
    def root?
      parents.empty?
    end

    def leaf?
      children.empty?
    end

    def make_root
      ancestor_links.delete_all
      parent_links.delete_all
      initialize_dag
    end

    # NOTE: Parents that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    def parents=(parents)
      (self.parents - parents).each do |parent_to_remove|
        remove_parent(parent_to_remove)
      end
      super
    end

    # NOTE: Children that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    def children=(children)
      (self.children - children).each do |child_to_remove|
        remove_child(child_to_remove)
      end
      super
    end

    # # NOTE: Parents that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    # def parent_ids=(parent_ids)
    #   parent_ids = parent_ids.collect(&:to_i)
    #   self.parents.reject {|parent| parent_ids.include? parent.id }.each do |parent_to_remove|
    #     remove_parent(parent_to_remove)
    #   end
    #   super
    # end

    # # NOTE: Children that are removed will not trigger the destroy callback on their link, so we need to remove them manually
    # def child_ids=(child_ids)
    #   child_ids = child_ids.collect(&:to_i)
    #   self.children.reject {|child| child_ids.include? child.id }.each do |child_to_remove|
    #     remove_child(child_to_remove)
    #   end
    #   super
    # end


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

    private

    # CALLBACKS

    def initialize_dag
      descendant_links.first_or_create!(:descendant_id => self.id, :distance => 0) # Self Descendant
      parent_links.first_or_create!(:parent_id => nil) # Root link
    end
  end

  module HelperMethods
    # creates a single link in the given link_class's link table between parent and
    # child object ids and creates the appropriate entries in the descendant table
    def self.link(parent, child)
      # Sanity check
      raise "Parent has no ID" if parent.id.nil?
      raise "Child has no ID" if child.id.nil?
      raise "Parent and child must be the same class" if parent.class != child.class

      klass = child.class

      # Return if the link already exists because we can assume that the proper descendants already exist too
      return if klass.link_table_entries.where(:parent_id => parent.id, :child_id => child.id).exists?

      # Create a new parent-child link
      klass.link_table_entries.create!(:parent_id => parent.id, :child_id => child.id)

      # If we have been passed a parent, find and destroy any existing links from nil (root) to the child as it can no longer be a top-level node
      unlink(nil, child) if parent
    end

    def self.update_transitive_closure_for_new_link(new_link)
      klass = new_link.node_class

      # If we're passing :parents or :children to a new record as part of #create, transitive closure on the nested records will
      # be updated before the new record's after save calls :initialize_dag. We ensure it's been initalized before we start querying
      # its descendant_table or it won't appear as an ancestor or descendant until too late.
      new_link.parent.send(:initialize_dag) if new_link.parent && new_link.parent.id_changed?
      new_link.child.send(:initialize_dag) if new_link.child && new_link.child.id_changed?


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

      # Now destroy all affected descendant_links (ancestors of parent (C), descendants of child (D))
      klass.descendant_table_entries.where(:ancestor_id => parent.path_ids, :descendant_id => child.subtree_ids).delete_all

      # Now iterate through all ancestors of the descendant_links that were deleted and pick only those that have no parents, namely (A, D)
      # These will be the starting points for the recreation of descendant links
      starting_points = klass.find(parent.path_ids + child.subtree_ids).select{|node| node.parents.empty? || node.parents == [nil] }

      # POSSIBLE OPTIMIZATION: The two starting points may share descendants. We only need to process each node once, so if we could skip dups, that would be good
      starting_points.each{|node| rebuild_descendant_links(node)}
    end


    # Create a descendant link to iteself, then iterate through all children
    # We add this node to the ancestor array we received
    # Then we create a descendant link between it and all nodes in the array we were passed (nodes traversed between it and all its ancestors affected by the unlinking).
    # Then iterate to all children of the current node passing the ancestor array along
    def self.rebuild_descendant_links(current, path = [])
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
        rebuild_descendant_links(child, path.dup)
      end
    end
  end

  # CLASSES (for providing hooks)
  class AbstractLink < ActiveRecord::Base
    self.abstract_class = true

    validate :not_self_referential

    def not_self_referential
      errors.add(:base, "Self referential links #{self.class} cannot be created.") if parent_id == child_id
    end
  end

  class AbstractDescendant < ActiveRecord::Base
    self.abstract_class = true

    validates_presence_of :ancestor_id, :descendant_id
  end
end
