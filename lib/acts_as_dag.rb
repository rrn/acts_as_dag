module ActsAsDAG
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def acts_as_dag(options = {})

      link_class = "#{self.name}Link"
      descendant_class = "#{self.name}Descendant"

      class_eval <<-EOV
      class ::#{link_class} < ActiveRecord::Base
        include ActsAsDAG::LinkClassInstanceMethods
        
        validate :not_circular_link

        belongs_to :parent, :class_name => '#{self.name}', :foreign_key => 'parent_id'
        belongs_to :child, :class_name => '#{self.name}', :foreign_key => 'child_id'
      end

      class ::#{descendant_class} < ActiveRecord::Base
        belongs_to :ancestor, :class_name => '#{self.name}', :foreign_key => "ancestor_id"
        belongs_to :descendant, :class_name => '#{self.name}', :foreign_key => "descendant_id"
      end

      def acts_as_dag_class
        ::#{self.name}
      end

      def self.link_type
        ::#{link_class}
      end

      def self.descendant_type
        ::#{descendant_class}
      end

      has_many :parent_links, :class_name => '#{link_class}', :foreign_key => 'child_id', :dependent => :destroy
      has_many :parents, :through => :parent_links, :source => :parent
      has_many :child_links, :class_name => '#{link_class}', :foreign_key => 'parent_id', :dependent => :destroy
      has_many :children, :through => :child_links, :source => :child

      # Ancestors must always be returned in order of most distant to least
      # Descendants must always be returned in order of least distant to most
      # NOTE: multiple instances of the same descendant/ancestor may be returned if there are multiple paths from ancestor to descendant
      #   A
      #  / \
      # B   C
      #  \ /
      #   D
      #
      has_many :ancestor_links, :class_name => '#{descendant_class}', :foreign_key => 'descendant_id', :dependent => :destroy
      has_many :ancestors, :through => :ancestor_links, :source => :ancestor, :order => "distance DESC"
      has_many :descendant_links, :class_name => '#{descendant_class}', :foreign_key => 'ancestor_id', :dependent => :destroy
      has_many :descendants, :through => :descendant_links, :source => :descendant, :order => "distance ASC"
      EOV
      
      include ActsAsDAG::InstanceMethods

      after_create :initialize_links
      after_create :initialize_descendants

      named_scope :roots, {:joins => :parent_links, :conditions => "parent_id IS NULL"}

      # Remove all hierarchy information for this category
      def reset_hierarchy
        logger.info "Clearing #{self.name} hierarchy links"
        link_type.delete_all
        find_each(&:initialize_links)

        logger.info "Clearing #{self.name} hierarchy descendants"
        descendant_type.delete_all
        find_each(&:initialize_descendants)
      end

      # Reorganizes the entire class of records, first resetting the hierarchy, then reoganizing
      def reorganize_all
        # Reorganize categories that need reorganization
        # Remove all hierarchy information for categories we're going to rearrange so
        # all categories are processed and we avoid the following situation:
        # e.g. ivory -> walrus ivory. then walrus added, but doesn't see walrus ivory
        # because it's under ivory and not at the top level
        reset_hierarchy
        reorganize
      end

      # Organizes sibling categories based on their name.
      # eg. "fibre" -> "hemp fibre" has a sibling "indian hemp fibre",
      # "indian hemp fibre" needs to be reorganized underneath "hemp fibre" because of its name
      def reorganize(starting_nodes = nil)
        case starting_nodes
        when self
          # When we pass an instance of this class and want its children reorganized
          parent = starting_nodes
          siblings = starting_nodes.children
        when nil
          # When we pass nothing and want all root nodes reorganized
          siblings = self.roots
        else
          # When we pass an array and want each node reorganized
          siblings = starting_nodes
        end
        
        logger.info {"reorganizing #{siblings.collect(&:name).to_sentence}#{' which are children of ' + parent.name if parent}"}
        for current_category in siblings
          for sibling in siblings
            next if current_category == sibling
            if sibling.should_descend_from? current_category
              logger.info "#{sibling.name} should descend from #{current_category.name}"

              # This category no longer descends from its parent
              parent.remove_child(sibling) if parent

              current_category.plinko(sibling)
            end
          end
        end
      end
    end
  end

  module InstanceMethods
    # Reorganizes all children of this category (self)
    def reorganize
      self.class.reorganize(self)
    end

    # Searches all descendants for the best parent for the other
    # i.e. it lets you drop the category in at the top and it drops down the list until it finds its final resting place
    def plinko(other)
      if other.should_descend_from?(self)
        # Sort the descendants (including self) by the number of matching words and reverse it so the most matching words are first
        # Then find the first one that +other+ should descend from
        if new_parent = descendants.sort_by{|category| self.matching_word_count(category)}.reverse.detect{|category| other.should_descend_from?(category)}
          other.add_parent(new_parent)
          # Reorganize the children of the new parent because the category we just added might be a potential parent of one of its new siblings
          new_parent.reorganize

          # We've just affected the associations in ways we can not possibly imagine, so let's just reload
          self.reload 
          return true
        end
      end
    end

    # Adds a category as a parent of this category (self)
    def add_parent(parent)
      link(parent, self)
    end

    # Adds a category as a child of this category (self)
    def add_child(child)
      link(self, child)
    end

    # Removes a category as a child of this category (self)
    # Returns the child
    def remove_child(child)
      unlink(self, child)
      return child
    end

    # Removes a category as a parent of this category (self)
    # Returns the parent
    def remove_parent(parent)
      unlink(parent, self)
      return parent
    end

    # Returns the portion of this category's name that is not present in any of it's parents
    def unique_name_portion
      unique_portion = name.split
      for parent in parents
        for word in parent.name.split
          unique_portion.delete(word)
        end
      end

      return unique_portion.empty? ? nil : unique_portion.join(' ')
    end

    # Returns true if the category's descendants include *self*
    def descendant_of?(category, options = {})
      ancestors.exists?(category)
    end

    # Returns true if the category's descendants include *self*
    def ancestor_of?(category, options = {})
      descendants.exists?(category)
    end

    # Checks if self should descend from +other+ based on name matching
    # Returns true if self contains all the words from +other+, but has words that are not contained in +other+
    def should_descend_from?(other)
      other_words = other.name.split
      self_words = self.name.split
      
      # (self contains all the words from other and more) && (other contains no words that are not also in self)
      return (self_words - (other_words & self_words)).count > 0 && (other_words - self_words).count == 0
    end
    
    def matching_word_count(other)
      other_words = other.name.split
      self_words = self.name.split
      return (other_words & self_words).count
    end
    
    def link_type
      self.class.link_type
    end

    def descendant_type
      self.class.descendant_type
    end

    def child_ids
      child_links.collect(&:child_id)
    end

    def parent_ids
      parent_links.collect(&:parent_id)
    end
    
    def descendant_ids
      descendant_links.collect(&:descendant_id)
    end

    def ancestor_ids
      ancestor_links.collect(&:ancestor_id)
    end

    # CALLBACKS
    def initialize_links
      link_type.new(:parent_id => nil, :child_id => id).save!
    end

    def initialize_descendants
      descendant_type.new(:ancestor_id => id, :descendant_id => id, :distance => 0).save!
    end
    # END CALLBACKS

    private
    
    # LINKING FUNCTIONS

    # creates a single link in the given link_type's link table between parent and
    # child object ids and creates the appropriate entries in the descendant table
    def link(parent, child)
#      logger.info "link(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_type}, parent = #{parent.name}, child = #{child.name})"

      # Check if parent and child have id's
      raise "Parent has no ID" if parent.id.nil?
      raise "Child has no ID" if child.id.nil?

      # Create a new parent-child link
      # Return unless the save created a new database entry and was not replaced with an existing database entry.
      # If we found one that already exists, we can assume that the proper descendants already exist too
      if new_link = link_type.find_or_initialize_by_parent_id_and_child_id(:parent_id => parent.id, :child_id => child.id)
        new_link.save!
      else
        logger.info "Skipping #{descendant_type} update because the link #{link_type} ##{new_link.id} already exists"
        return
      end

      # If we have been passed a parent, find and destroy any existing links from nil (root) to the child as it can no longer be a top-level node
      unlink(nil, child) if parent

      # The parent and all its ancestors need to be added as ancestors of the child
      # The child and all its descendants need to be added as descendants of the parent

      # get parent ancestor id list
      parent_ancestor_links = descendant_type.find(:all, :conditions => { :descendant_id => parent.id }) # (totem => totem pole), (totem_pole => totem_pole)
      # get child descendant id list
      child_descendant_links = descendant_type.find(:all, :conditions => { :ancestor_id => child.id }) # (totem pole model => totem pole model)
      for parent_ancestor_link in parent_ancestor_links
        for child_descendant_link in child_descendant_links
          descendant_type.find_or_initialize_by_ancestor_id_and_descendant_id_and_distance(:ancestor_id => parent_ancestor_link.ancestor_id, 
          :descendant_id => child_descendant_link.descendant_id, 
          :distance => parent_ancestor_link.distance + child_descendant_link.distance + 1).save!
        end
      end
    end

    # breaks a single link in the given hierarchy_link_table between parent and
    # child object id. Updates the appropriate Descendants table entries
    def unlink(parent, child)
      descendant_table_string = descendant_type.to_s
#      logger.info "unlink(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_table_string}, parent = #{parent ? parent.name : 'nil'}, child = #{child.name})"

      # Raise an exception if there is no child
      raise "Child cannot be nil when deleting a category_link" unless child

      # delete the links
      link_type.delete_all(:parent_id => (parent ? parent.id : nil), :child_id => child.id)

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
      descendant_type.delete_all(:ancestor_id => parent.ancestor_ids, :descendant_id => child.descendant_ids)
      
      # Now iterate through all ancestors of the descendant_links that were deleted and pick only those that have no parents, namely (A, D)
      # These will be the starting points for the recreation of descendant links
      starting_points = self.class.find(parent.ancestor_ids + child.descendant_ids).select{|node| node.parents.empty? || node.parents == [nil] }
      logger.info {"starting points are #{starting_points.collect(&:name).to_sentence}" }

      # POSSIBLE OPTIMIZATION: The two starting points may share descendants. We only need to process each node once, so if we could skip dups, that would be good
      starting_points.each{|node| node.send(:rebuild_descendant_links)}
    end

    # Create a descendant link to iteself, then iterate through all children
    # We add this node to the ancestor array we received
    # Then we create a descendant link between it and all nodes in the array we were passed (nodes traversed between it and all its ancestors affected by the unlinking).          
    # Then iterate to all children of the current node passing the ancestor array along
    def rebuild_descendant_links(ancestors = [])
      indent = ""
      ancestors.size.times do |index|
        indent << "  "
      end

      logger.info {"#{indent}Rebuilding descendant links of #{self.name}"}
      # Add self to the list of traversed nodes that we will pass to the children we decide to recurse to
      ancestors << self
      
      # Create descendant links to each ancestor in the array (including itself)
      ancestors.reverse.each_with_index do |ancestor, index|
        logger.info {"#{indent}#{ancestor.name} is an ancestor of #{self.name} with distance #{index}"}
        descendant_type.find_or_initialize_by_ancestor_id_and_descendant_id_and_distance(:ancestor_id => ancestor.id, :descendant_id => self.id, :distance => index).save!
      end
      
      # Now check each child to see if it is a descendant, or if we need to recurse
      dids = descendant_ids
      for child in children
        logger.info {"#{indent}Recursing to #{child.name}"}
        child.send(:rebuild_descendant_links, ancestors.dup)
      end
      logger.info {"#{indent}Done recursing"}
    end
    
    # END LINKING FUNCTIONS

    # GARBAGE COLLECTION
    # Remove all entries from this object's table that are not associated in some way with an item
    def self.garbage_collect
      table_prefix = self.class.name.tableize
      root_locations = self.class.find(:all, :conditions => "#{table_prefix}_links.parent_id IS NULL", :include => "#{table_prefix}_parents")
      for root_location in root_locations
        root_location.garbage_collect
      end
    end

    def garbage_collect
      # call garbage collect on all children,
      # Return false if any of those are unsuccessful, thus cancelling the recursion chain
      for child in children
        return false unless child.garbage_collect
      end

      if events.blank?
        destroy
        logger.info "Deleted RRN #{self.class} ##{id} (#{name}) during garbage collection"
        return true
      else
        return false
      end
    end
    # END GARBAGE COLLECTION
  end

  module LinkClassInstanceMethods
    def not_circular_link
      errors.add_to_base("Circular #{self.class} cannot be created.") if parent_id == child_id
    end
  end
end

if Object.const_defined?("ActiveRecord")
  ActiveRecord::Base.send(:include, ActsAsDAG)
end