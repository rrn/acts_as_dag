module ActiveRecord
  module Acts #:nodoc:
    module DAG #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_dag(options = {})

          link_class = "#{self.name}Link"
          descendant_class = "#{self.name}Descendant"

          class_eval <<-EOV
            class ::#{link_class} < ActiveRecord::Base
              include ActiveRecord::Acts::DAG::LinkClassInstanceMethods

              acts_as_replaceable :conditions => [:child_id, :parent_id]

              belongs_to :parent, :class_name => '#{self.name}', :foreign_key => 'parent_id'
              belongs_to :child, :class_name => '#{self.name}', :foreign_key => 'child_id'
            end

            class ::#{descendant_class} < ActiveRecord::Base
              include ActiveRecord::Acts::DAG::DescendantClassInstanceMethods

              acts_as_replaceable :conditions => [:ancestor_id, :descendant_id]

              belongs_to :ancestor, :class_name => '#{self.name}', :foreign_key => "ancestor_id"
              belongs_to :descendant, :class_name => '#{self.name}', :foreign_key => "descendant_id"
            end

            include ActiveRecord::Acts::DAG::InstanceMethods

            attr_reader :create_links, :create_descendants

            def initialize(params = {})
              # allow user to disable creation of DAG entries on creation
              @create_links = params.delete(:create_links)
              @create_descendants = params.delete(:create_descendants)
              super(params)
            end

            def acts_as_dag_class
              ::#{self.name}
            end

            def link_type
              ::#{link_class}
            end

            def descendant_type
              ::#{descendant_class}
            end

            after_create :initialize_links
            after_create :initialize_descendants

            has_many :parent_links, :class_name => '#{link_class}', :foreign_key => 'child_id'
            has_many :parents, :through => :parent_links, :source => :parent
            has_many :child_links, :class_name => '#{link_class}', :foreign_key => 'parent_id'
            has_many :children, :through => :child_links, :source => :child

            # Ancestors must always be returned in order of most distant to least
            # Descendants must always be returned in order of least distant to most
            has_many :ancestor_links, :class_name => '#{descendant_class}', :foreign_key => 'descendant_id'
            has_many :ancestors, :through => :ancestor_links, :source => :ancestor, :order => "distance DESC"
            has_many :descendant_links, :class_name => '#{descendant_class}', :foreign_key => 'ancestor_id'
            has_many :descendants, :through => :descendant_links, :source => :descendant, :order => "distance ASC"
          EOV

          # Removes category_being_cleaned's children that are descendants of another one of category_being_cleaned's children
          # Typically used on category1 after category2 is added as a child without first checking if category1 has a child that should be the parent of category2
          def self.remove_indirect_descendant_children(category_being_cleaned)
            current_child_list = category_being_cleaned.children
            for current_child in current_child_list
              Log.debug {"Checking if #{category_being_cleaned.name} has children that are descendants of #{current_child.name}"}
              for other_child in current_child_list
                # remove the spurious child of *self*, exclude self because the function returns self as a descendant with distance 0
                if other_child.descends_from?(current_child, :exclude_self => true)
                  Log.debug {"#{category_being_cleaned.name} contains #{other_child.name} which is a descendant of #{category_being_cleaned.name}'s child #{current_child.name}"}
                  category_being_cleaned.remove_child(other_child)
                  # remove the child from the list of children we need to check because it is no longer a child
                  current_child_list.delete(other_child)
                end
              end
            end
          end

          # Reorganizes any child categories of category_being_cleaned, checking for categories that should not be direct descendants and moving them under the appropriate ancestor category, then recursively calls self on the category gaining the errant child
          def self.reorganize_indirect_descendant_children(category_being_cleaned, options = {})
            Log.call_stack {"reorganize_indirect_descendant_children(item_type_being_cleaned = #{category_being_cleaned.name})"}
            if category_being_cleaned.children_have_changed? or options[:force]
              children = category_being_cleaned.children
              for current_child in children
                for other_child in children
                  if current_child.should_descend_from?(other_child)
                    Log.info {"#{current_child.name} is being moved under #{other_child.name} because of a name-match"}
                    children.delete(current_child)
                    category_being_cleaned.remove_child(current_child)
                    other_child.add_child(current_child)
                    reorganize_indirect_descendant_children(other_child)
                  end
                end
              end
            else
              Log.info {"Children of #{category_being_cleaned.name} have not changed, skipping reorganize_indirect_descendant_children"}
            end
          end

          # Return all categories whose name contains the all the words in +string+
          # Options:
          #   :exclude_exact_match    - cause any categories whose name matches the search string exactly
          #   :exclude                - ensures that the single record, or array of records passed to not appear in the results
          def self.find_matches(string, options = {})
            # Create a 'similar to' condition for each word in the string
            conditions = Array.new
            for word in string.split
              conditions << "name SIMILAR TO '(% )*#{word}( %)*'"
            end

            # Optionally Exclude records with a name exactly matching the search string
            conditions << "name != '#{string}'" if options[:exclude_exact_match]

            # Optionally exclude results from the return values ( eg. if you don't want to return the item you're finding matches for )
            if options[:exclude].is_a?(self.class)
              conditions << "id != #{options[:exclude].id}"
            elsif options[:exclude].is_a?(Array) && !options[:exclude].empty?
              exclusion_list = options[:exclude].collect{|record| record.id}
              conditions << "id NOT IN (#{exclusion_list.join(',')})"
            end

            return find(:all, :conditions => conditions.join(' AND '))
          end
        end
      end

      # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
      # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
      # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
      # the first in the list of all chapters.
      module InstanceMethods
        attr_accessor :parents_have_changed, :children_have_changed

        # True if a link has been created to this object specifying it as the parent
        def children_have_changed?
          @children_have_changed
        end

        # True if a link has been created to this object specifying it as the child
        def parents_have_changed?
          @parents_have_changed
        end

        # Adds a category as a parent of this category (self)
        def add_parent(parent, metadata = {})
          link(parent, self, metadata)
        end

        # Adds a category as a child of this category (self)
        def add_child(child, metadata = {})
          link(self, child, metadata)
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
        # Excludes self from list of results if params[:exclude_self] != false
        def descends_from?(category, options = {})
          sql = "ancestor_id = #{category.id} AND descendant_id = #{self.id}"
          sql << " AND distance > 0" if options[:exclude_self]
          descendant_type.count(:conditions => sql) > 0 ? true : false
        end

        # Checks if self should descend from possible_ancestor based on name matching
        # Returns true if self contains all the words from ancestor, but has words that are not contained in ancestor
        def should_descend_from?(ancestor)
          ancestor_name_words = ancestor.name.split
          descendant_name_words = self.name.split

          # Delete all the words contained in the ancestor's name from the descendant's name
          # Return false, if one of the words is not contained in the descendant's name
          for word in ancestor_name_words
            unless descendant_name_words.delete(word)
              return false
            end
          end

          # Check if there are still words remaining in the list of descendant words
          # If there are, it means that the descendant name contains all the words from the ancestor, plus some others, and is therefore a descendant
          if descendant_name_words.empty?
            return false
          else
            return true
          end
        end

        private
        # CALLBACKS
        def initialize_links
          raise 'initialized links for existing record' if @has_been_replaced
          link_type.new(:parent_id => nil, :child_id => id).save! unless @create_links.eql? false
        end

        def initialize_descendants
          raise 'initialized descendants for existing record' if @has_been_replaced
          descendant_type.new(:ancestor_id => id, :descendant_id => id, :distance => 0).save! unless @create_descendants.eql? false
        end
        # END CALLBACKS

        # LINKING FUNCTIONS

        # creates a single link in the given link_type's link table between parent and
        # child object ids and creates the appropriate entries in the descendant table
        def link(parent, child, metadata = {})

          #Log.call_stack {"link(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_type}, parent = #{parent.name}, child = #{child.name})"}

          # Check if parent and child have id's
          raise "Parent has no ID" if parent.id.nil?
          raise "Child has no ID" if child.id.nil?

          # Create a new parent-child link
          new_link = link_type.new(:parent => parent, :child => child)
          new_link.attributes = metadata
          new_link.save!

          # If the link is invalid we should not continue
          unless new_link.valid?
            Log.info {"Skipping #{descendant_type} update because the link #{link_type} ##{new_link.id} was invalid"}
            return
          end

          # Return unless the save created a new database entry and was not replaced with an existing database entry.
          # If we found one that already exists, we can assume that the proper descendants already exist too
          if new_link.has_been_replaced
            #Log.info {"Skipping #{descendant_type} update because the link #{link_type} ##{link.id} already exists"}
            return
          end

          # If we have been passed a parent, find and destroy any exsting links from nil (root) to the child as it can no longer be a top-level node
          unlink(nil, child) if parent

          # update descendants listing by creating links from the parent and its
          # ancestors to the child and its descendants

          # get parent ancestor id list
          parent_ancestor_links = descendant_type.find(:all, :conditions => { :descendant_id => parent.id })
          # get child descendant id list
          child_descendant_links = descendant_type.find(:all, :conditions => { :ancestor_id => child.id })
          for parent_ancestor_link in parent_ancestor_links
            for child_descendant_link in child_descendant_links
              descendant_link = descendant_type.new
              # get the ancestor id from the parent's ancestor that we are making a
              # link from
              descendant_link.ancestor_id = parent_ancestor_link.ancestor_id
              # get the descendant id from the child's descendant that we are making a
              # link to
              descendant_link.descendant_id = child_descendant_link.descendant_id
              # get the distance as the sum of the distance from the ancestor to the
              # parent and from the child to the descendant
              descendant_link.distance = parent_ancestor_link.distance + child_descendant_link.distance + 1

              descendant_link.attributes = metadata
              descendant_link.save!
            end
          end
        end

        # breaks a single link in the given hierarchy_link_table between parent and
        # child object id. Updates the appropriate Descendants table entries
        def unlink(parent, child)
          #          parent_name = parent ? parent.name : 'Root'
          #          child_name = child.name

          descendant_table_string = descendant_type.to_s
          #Log.call_stack "unlink(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_table_string}, parent = #{parent_name}, child = #{child_name})"

          # Raise an exception if there is no child
          raise "Child cannot be nil when deleting a category_link" unless child

          parent_id_constraint = parent ? "parent_id = #{parent.id}" : "parent_id is null"
          child_id_constraint = "child_id = #{child.id}"

          # delete the links
          link_type.delete_all("#{parent_id_constraint} AND #{child_id_constraint}")

          # update descendants listing by deleting all links from the parent and its
          # ancestors to the child and its descendants

          # deal with nil parent when category is top-level
          parent_ancestor_id_condition = parent ? "IN (SELECT ancestor_id FROM #{descendant_table_string.tableize} WHERE descendant_id = #{parent.id})" : "IS NULL"
          child_descendant_id_condition = "IN (SELECT descendant_id FROM #{descendant_table_string.tableize} WHERE ancestor_id = #{child.id})"

          # delete (any combination of ancestor and descendant should be a link we
          # need to delete)
          descendant_type.delete_all("ancestor_id #{parent_ancestor_id_condition} AND descendant_id #{child_descendant_id_condition}")
        end
        # END LINKING FUNCTIONS

        # GARBAGE COLLECTION
        # Remove all entries from this object's table that are not associated in some way with an item
        def self.garbage_collect
          class_name = self.class.to_s.tableize
          root_locations = self.class.find(:all, :conditions => "#{class_name}_links.parent_id IS NULL", :include => "#{class_name}_parents")
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
            #              Log.info "Deleted RRN #{self.class} ##{id} (#{name}) during garbage collection"
            return true
          else
            return false
          end
        end
        # END GARBAGE COLLECTION
      end

      module LinkClassInstanceMethods
        def validate
          errors.add_to_base("Circular #{self.class} cannot be created.") if parent_id == child_id
        end

        def save!
          #          parent_name = parent ? parent.name : 'root'
          #          parent_id_string = parent ? parent_id : 'none'
          #          link_description = "linking #{parent.class} ##{parent_id_string} #{parent_name} (parent) to #{child.class} ##{child_id} #{child.name} (child)"

          # No need to save if we find an existing parent-child link since the link contains no information other than that which was used to find the existing record
          if replace(find_duplicate(:parent_id => parent_id, :child_id => child_id))
            #Log.info "Found existing #{self.class} ##{id} #{link_description}"
          end

          begin
            super
            #Log.info "Created #{self.class} ##{id} #{link_description}"
            inform_parents_and_children
          rescue => exception
            #SiteItemLog.error "RRN #{self.class} ##{id} #{link_description} - Couldn't save because #{exception.message}"
          end
        end

        private

        # Update the parent and child informing them that their respective links have been altered
        def inform_parents_and_children
          child.parents_have_changed = true
          parent.children_have_changed = true
        end
      end

      module DescendantClassInstanceMethods
        def save!
          #descendant_description = "linking #{ancestor.class} ##{ancestor_id} #{ancestor.name} (ancestor) to #{descendant.class} ##{descendant_id} #{descendant.name} (descendant)"

          # No need to save if we find an existing ancestor-descendant link since the link contains no information other than that which was used to find the existing record
          if replace(find_duplicate(:ancestor_id => ancestor_id, :descendant_id => descendant_id))
            #Log.info("Found existing #{self.class} ##{id} #{descendant_description}")
            return
          end

          begin
            super
            #Log.info("Created #{self.class} ##{id} #{descendant_description}")
          rescue => exception
            #SiteItemLog.error "RRN #{self.class} ##{id} #{descendant_description} - Couldn't save because #{exception.message}"
          end
        end
      end
    end
  end
end
