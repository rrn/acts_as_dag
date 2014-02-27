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
          belongs_to :parent,     :class_name => '#{self.name}', :foreign_key => :parent_id
          belongs_to :child,      :class_name => '#{self.name}', :foreign_key => :child_id
        end

        class ::#{options[:descendant_class]} < ActsAsDAG::AbstractDescendant
          self.table_name = '#{options[:descendant_table]}'
          belongs_to :ancestor,   :class_name => '#{self.name}', :foreign_key => :ancestor_id
          belongs_to :descendant, :class_name => '#{self.name}', :foreign_key => :descendant_id
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
      has_many :ancestors,        -> { order("#{descendant_class.table_name}.distance DESC") }, :through => :ancestor_links, :source => :ancestor
      has_many :descendants,      -> { order("#{descendant_class.table_name}.distance ASC") }, :through => :descendant_links, :source => :descendant

      has_many :ancestor_links,   -> { where options[:link_conditions] }, :class_name => descendant_class, :foreign_key => 'descendant_id', :dependent => :delete_all
      has_many :descendant_links, -> { where options[:link_conditions] }, :class_name => descendant_class, :foreign_key => 'ancestor_id', :dependent => :delete_all

      has_many :parents,          :through => :parent_links, :source => :parent
      has_many :children,         :through => :child_links, :source => :child
      has_many :parent_links,     -> { where options[:link_conditions] }, :class_name => link_class, :foreign_key => 'child_id', :dependent => :delete_all
      has_many :child_links,      -> { where options[:link_conditions] }, :class_name => link_class, :foreign_key => 'parent_id', :dependent => :delete_all

      # NOTE: Use select to prevent ActiveRecord::ReadOnlyRecord if the returned records are modified
      scope :roots,               -> { select("#{table_name}.*").joins(:parent_links).where(link_class.table_name => {:parent_id => nil}) }
      scope :children,            -> { select("#{table_name}.*").joins(:parent_links).where.not(link_class.table_name => {:parent_id => nil}).uniq }

      after_create :initialize_links
      after_create :initialize_descendants

      extend ActsAsDAG::ClassMethods
      include ActsAsDAG::InstanceMethods      
    end
  end

  module ClassMethods
    def acts_like_dag?
      true
    end

    # Reorganizes the entire class of records based on their name, first resetting the hierarchy, then reoganizing
    # Can pass a list of categories and only those will be reorganized
    def reorganize(categories_to_reorganize = self.all)
      return if categories_to_reorganize.empty?
      
      reset_hierarchy(categories_to_reorganize)

      word_count_groups = categories_to_reorganize.group_by{|category| ActsAsDAG::HelperMethods.word_count(category)}.sort
      roots_categories = word_count_groups.first[1].dup.sort_by(&:name)  # We will build up a list of plinko targets, we start with the group of categories with the shortest word count

      # Now plinko the next shortest word group into those targets
      # If we can't plinko one, then it gets added as a root
      word_count_groups[1..-1].each do |word_count, categories|
        categories_with_no_parents = []

        # Try drop each category into each root
        categories.sort_by(&:name).each do |category|
          start = Time.now
          suitable_parent = false
          roots_categories.each do |root|
            suitable_parent = true if ActsAsDAG::HelperMethods.plinko(root, category)
          end
          unless suitable_parent
            ActiveRecord::Base.logger.info { "Plinko couldn't find a suitable parent for #{category.name}" }
            categories_with_no_parents << category       
          end
          puts "took #{Time.now - start} to analyze #{category.name}"
        end

        # Add all categories from this group without suitable parents to the roots
        if categories_with_no_parents.present?
          ActiveRecord::Base.logger.info { "Adding #{categories_with_no_parents.collect(&:name).join(', ')} to roots" }
          roots_categories.concat categories_with_no_parents
        end
      end
    end

    # Remove all hierarchy information for this category
    # Can pass a list of categories to reset
    def reset_hierarchy(categories_to_reset = self.all)
      ids = categories_to_reset.collect(&:id)

      ActiveRecord::Base.logger.info { "Clearing #{self.name} hierarchy links" }
      link_table_entries.where("parent_id IN (?) OR child_id IN (?)", ids, ids).delete_all

      ActiveRecord::Base.logger.info { "Clearing #{self.name} hierarchy descendants" }
      descendant_table_entries.where("descendant_id IN (?) OR ancestor_id IN (?)", ids, ids).delete_all

      categories_to_reset.each do |category|
        category.send :initialize_links
        category.send :initialize_descendants
      end
    end    
  end

  module InstanceMethods
    # Returns true if this record is a root node
    def root?
      self.class.roots.exists? self
    end

    # Adds a category as a parent of this category (self)
    def add_parent(parent)
      ActsAsDAG::HelperMethods.link(parent, self)
    end

    # Adds a category as a child of this category (self)
    def add_child(child)
      ActsAsDAG::HelperMethods.link(self, child)
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

    # Returns true if the category's descendants include *self*
    def descendant_of?(category, options = {})
      ancestors.exists?(category)
    end

    # Returns true if the category's descendants include *self*
    def ancestor_of?(category, options = {})
      descendants.exists?(category)
    end

    # Returns the class used for links
    def link_class
      self.class.link_class
    end

    # Returns the class used for descendants
    def descendant_class
      self.class.descendant_class
    end

    private

    # CALLBACKS
    def initialize_links
      self.class.link_table_entries.create!(:parent_id => nil, :child_id => self.id) # Root link
    end

    def initialize_descendants
      self.class.descendant_table_entries.create!(:ancestor_id => self.id, :descendant_id => self.id, :distance => 0) # Self Descendant
    end
  end

  module HelperMethods
    # Searches all descendants for the best parent for the other
    # i.e. it lets you drop the category in at the top and it drops down the list until it finds its final resting place
    def self.plinko(current, other)
      # ActiveRecord::Base.logger.info { "Plinkoing '#{other.name}' into '#{current.name}'..." }
      if should_descend_from?(current, other)
        # Find the descendants of the current category that +other+ should descend from 
        descendants_other_should_descend_from = current.descendants.select{|descendant| should_descend_from?(descendant, other) }
        # Of those, find the categories with the most number of matching words and make +other+ their child
        # We find all suitable candidates to provide support for categories whose names are permutations of each other
        # e.g. 'goat wool fibre' should be a child of 'goat wool' and 'wool goat' if both are present under 'goat'
        new_parents_group = descendants_other_should_descend_from.group_by{|category| matching_word_count(other, category)}.sort.reverse.first
        if new_parents_group.present?
          for new_parent in new_parents_group[1]
            ActiveRecord::Base.logger.info { "  '#{other.name}' landed under '#{new_parent.name}'" }
            other.add_parent(new_parent)

            # We've just affected the associations in ways we can not possibly imagine, so let's clear the association cache
            current.clear_association_cache 
          end
          return true
        end
      end
    end

    # Convenience method for plinkoing multiple categories
    # Plinko's multiple categories from shortest to longest in order to prevent the need for reorganization
    def self.plinko_multiple(current, others)
      groups = others.group_by{|category| word_count(category)}.sort
      groups.each do |word_count, categories|
        categories.each do |category|
          unless plinko(current, category)
          end
        end
      end    
    end    

    # Returns the portion of this category's name that is not present in any of it's parents
    def self.unique_name_portion(current)
      unique_portion = current.name.split
      for parent in current.parents
        for word in parent.name.split
          unique_portion.delete(word)
        end
      end

      return unique_portion.empty? ? nil : unique_portion.join(' ')
    end

    # Checks if other should descend from +current+ based on name matching
    # Returns true if other contains all the words from +current+, but has words that are not contained in +current+
    def self.should_descend_from?(current, other)
      return false if current == other

      other_words = other.name.split
      current_words = current.name.split

      # (other contains all the words from current and more) && (current contains no words that are not also in other)
      return (other_words - (current_words & other_words)).count > 0 && (current_words - other_words).count == 0
    end

    def self.word_count(current)
      current.name.split.count
    end

    def self.matching_word_count(current, other)
      other_words = other.name.split
      self_words = current.name.split
      return (other_words & self_words).count
    end

    # creates a single link in the given link_class's link table between parent and
    # child object ids and creates the appropriate entries in the descendant table
    def self.link(parent, child)
      #      ActiveRecord::Base.logger.info { "link(hierarchy_link_table = #{child.link_class}, hierarchy_descendant_table = #{child.descendant_class}, parent = #{parent.name}, child = #{child.name})" }

      # Sanity check
      raise "Parent has no ID" if parent.id.nil?
      raise "Child has no ID" if child.id.nil?
      raise "Parent and child must be the same class" if parent.class != child.class

      klass = child.class

      # Create a new parent-child link
      # Return if the link already exists because we can assume that the proper descendants already exist too
      if klass.link_table_entries.where(:parent_id => parent.id, :child_id => child.id).exists?
        ActiveRecord::Base.logger.info { "Skipping #{child.descendant_class} update because the link already exists" }
        return
      else
        klass.link_table_entries.create!(:parent_id => parent.id, :child_id => child.id)
      end

      # If we have been passed a parent, find and destroy any existing links from nil (root) to the child as it can no longer be a top-level node
      unlink(nil, child) if parent

      # The parent and all its ancestors need to be added as ancestors of the child
      # The child and all its descendants need to be added as descendants of the parent

      # get parent ancestor id list
      parent_ancestor_links = klass.descendant_table_entries.where(:descendant_id => parent.id) # (totem => totem pole), (totem_pole => totem_pole)
      # get child descendant id list
      child_descendant_links = klass.descendant_table_entries.where(:ancestor_id => child.id) # (totem pole model => totem pole model)
      for parent_ancestor_link in parent_ancestor_links
        for child_descendant_link in child_descendant_links
          klass.descendant_table_entries.find_or_create_by!(:ancestor_id => parent_ancestor_link.ancestor_id, :descendant_id => child_descendant_link.descendant_id, :distance => parent_ancestor_link.distance + child_descendant_link.distance + 1)
        end
      end
    end

    # breaks a single link in the given hierarchy_link_table between parent and
    # child object id. Updates the appropriate Descendants table entries
    def self.unlink(parent, child)
      descendant_table_string = child.descendant_class.to_s
      #      ActiveRecord::Base.logger.info { "unlink(hierarchy_link_table = #{child.link_class}, hierarchy_descendant_table = #{descendant_table_string}, parent = #{parent ? parent.name : 'nil'}, child = #{child.name})" }

      # Raise an exception if there is no child
      raise "Child cannot be nil when deleting a category_link" unless child

      klass = child.class

      # delete the links
      klass.link_table_entries.where(:parent_id => parent.try(:id), :child_id => child.id).delete_all

      # If the parent was nil, we don't need to update descendants because there are no descendants of nil
      return unless parent

      # We have unlinked C and D
      #                 A   F
      #                / \ /
      #               B   C
      #               |   
      #               |   D
      #                \ /
      #                 E
      #
      # Now destroy all affected descendant_links (ancestors of parent (C), descendants of child (D))
      klass.descendant_table_entries.where(:ancestor_id => parent.ancestor_ids, :descendant_id => child.descendant_ids).delete_all

      # Now iterate through all ancestors of the descendant_links that were deleted and pick only those that have no parents, namely (A, D)
      # These will be the starting points for the recreation of descendant links
      starting_points = klass.find(parent.ancestor_ids + child.descendant_ids).select{|node| node.parents.empty? || node.parents == [nil] }
      ActiveRecord::Base.logger.info {"starting points are #{starting_points.collect(&:name).to_sentence}" }

      # POSSIBLE OPTIMIZATION: The two starting points may share descendants. We only need to process each node once, so if we could skip dups, that would be good
      starting_points.each{|node| rebuild_descendant_links(node)}
    end

    # Create a descendant link to iteself, then iterate through all children
    # We add this node to the ancestor array we received
    # Then we create a descendant link between it and all nodes in the array we were passed (nodes traversed between it and all its ancestors affected by the unlinking).          
    # Then iterate to all children of the current node passing the ancestor array along
    def self.rebuild_descendant_links(current, ancestors = [])
      indent = Array.new(ancestors.size, "  ").join
      klass = current.class

      ActiveRecord::Base.logger.info {"#{indent}Rebuilding descendant links of #{current.name}"}
      # Add current to the list of traversed nodes that we will pass to the children we decide to recurse to
      ancestors << current

      # Create descendant links to each ancestor in the array (including itself)
      ancestors.reverse.each_with_index do |ancestor, index|
        ActiveRecord::Base.logger.info {"#{indent}#{ancestor.name} is an ancestor of #{current.name} with distance #{index}"}
        klass.descendant_table_entries.find_or_create_by!(:ancestor_id => ancestor.id, :descendant_id => current.id, :distance => index)
      end

      # Now check each child to see if it is a descendant, or if we need to recurse
      for child in current.children
        ActiveRecord::Base.logger.info {"#{indent}Recursing to #{child.name}"}
        rebuild_descendant_links(child, ancestors.dup)
      end
      ActiveRecord::Base.logger.info {"#{indent}Done recursing"}
    end
  end

  # CLASSES (for providing hooks)
  class AbstractLink < ActiveRecord::Base
    self.abstract_class = true

    validates_presence_of :child_id
    validate :not_self_referential

    def not_self_referential
      errors.add_to_base("Self referential links #{self.class} cannot be created.") if parent_id == child_id
    end
  end

  class AbstractDescendant < ActiveRecord::Base
    self.abstract_class = true

    validates_presence_of :ancestor_id, :descendant_id
  end
end