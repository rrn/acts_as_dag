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

            def self.link_type
              ::#{link_class}
            end

            def self.descendant_type
              ::#{descendant_class}
            end

            def link_type
              self.class.link_type
            end

            def descendant_type
              self.class.descendant_type
            end

            after_create :initialize_links
            after_create :initialize_descendants

            has_many :parent_links, :class_name => '#{link_class}', :foreign_key => 'child_id', :dependent => :destroy
            has_many :parents, :through => :parent_links, :source => :parent
            has_many :child_links, :class_name => '#{link_class}', :foreign_key => 'parent_id', :dependent => :destroy
            has_many :children, :through => :child_links, :source => :child

            # Ancestors must always be returned in order of most distant to least
            # Descendants must always be returned in order of least distant to most
            has_many :ancestor_links, :class_name => '#{descendant_class}', :foreign_key => 'descendant_id', :dependent => :destroy
            has_many :ancestors, :through => :ancestor_links, :source => :ancestor, :order => "distance DESC"
            has_many :descendant_links, :class_name => '#{descendant_class}', :foreign_key => 'ancestor_id', :dependent => :destroy
            has_many :descendants, :through => :descendant_links, :source => :descendant, :order => "distance ASC"
          EOV

          # Remove all hierarchy information for this category
          def reset_hierarchy
            logger.info "Clearing #{self.class.name} hierarchy links"
            link_type.delete_all
            all.each(&:initialize_links)

            logger.info "Clearing #{self.class.name} hierarchy descendants"
            descendant_type.delete_all
            all.each(&:initialize_descendants)
          end


          # Organizes sibling categories based on their name.
          # eg. "fibre" -> "hemp fibre" has a sibling "indian hemp fibre",
          # "indian hemp fibre" needs to be reorganized underneath "hemp fibre" because of its name
          def reorganize(siblings, parent = nil)
            # Cross compare each sibling.
            for current_category in siblings
              for sibling in siblings
                # If this category should descend from any other sibling,
                # Remove its parents and place it under its sibling
                if current_category.should_descend_from?(sibling)
                  logger.info "Reorganizing: #{current_category.name} should descend from #{sibling.name}"
                  # If the current_category still has parent as a parent
                  # (which it may not if another sibling has also claimed it as a
                  # child, eg. in the case of "spindle" and "whorl" both claiming "spindle whorl"),
                  # remove it
                  if current_category.parents.include?(parent)
                    parent.remove_child(current_category)
                  end
                  # add the current_category as a child of its sibling
                  sibling.add_child(current_category)
                end
              end
            end

            # Recurse down the hierarchy applying the same rules to each level
            siblings.each do |category|
              reorganize(category.children, category)
            end
          end

          # Return all categories whose name contains the all the words in +string+
          # Options:
          #   :exclude_exact_match    - cause any categories whose name matches the search string exactly
          #   :exclude                - ensures that the single record, or array of records passed to not appear in the results
          def self.find_matches(string, options = {})
            # Create a 'similar to' condition for each word in the string
            sql = Array.new
            vars = Array.new
            for word in string.split
              sql << "name ~ ?"
              vars << "\\y#{Regexp.escape(word)}\\y"
            end

            # Optionally Exclude records with a name exactly matching the search string
            if options[:exclude_exact_match]
            sql << "name != ?"
            vars << string
            end

            # Optionally exclude results from the return values ( eg. if you don't want to return the item you're finding matches for )
            if options[:exclude].is_a?(self.class)
              sql << "id != ?"
              sql << options[:exclude].id
            elsif options[:exclude].is_a?(Array) && !options[:exclude].empty?
              exclusion_list = options[:exclude].collect{|record| record.id}
              sql << "id NOT IN (?)"
              vars << exclusion_list.join(',')
            end

            # Create the conditions array so rails will escape it.
            conditions = [sql.join(' AND ')].concat(vars)

            return find(:all, :conditions => conditions)
          end
        end
      end

      module InstanceMethods
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
          logger.call_stack "link(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_type}, parent = #{parent.name}, child = #{child.name})"

          # Check if parent and child have id's
          raise "Parent has no ID" if parent.id.nil?
          raise "Child has no ID" if child.id.nil?

          # Create a new parent-child link
          new_link = link_type.find_or_initialize_by_parent_id_and_child_id(:parent_id => parent.id, :child_id => child.id)

          # Return unless the save created a new database entry and was not replaced with an existing database entry.
          # If we found one that already exists, we can assume that the proper descendants already exist too
          if new_link.new_record?
            new_link.attributes = metadata
            new_link.save!
          else
            logger.info "Skipping #{descendant_type} update because the link #{link_type} ##{new_link.id} already exists"
            return
          end

          # If we have been passed a parent, find and destroy any exsting links from nil (root) to the child as it can no longer be a top-level node
          unlink(nil, child) if parent

          # The parent and all its ancestors need to be added as ancestors of the child
          # The child and all its descendants need to be added as descendants of the parent

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
          parent_name = parent ? parent.name : 'Root'
          child_name = child.name

          descendant_table_string = descendant_type.to_s
          logger.call_stack "unlink(hierarchy_link_table = #{link_type}, hierarchy_descendant_table = #{descendant_table_string}, parent = #{parent_name}, child = #{child_name})"

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
            logger.info "Deleted RRN #{self.class} ##{id} (#{name}) during garbage collection"
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
          parent_name = parent ? parent.name : 'root'
          parent_id_string = parent ? parent_id : 'none'
          link_description = "linking #{parent.class} ##{parent_id_string} #{parent_name} (parent) to #{child.class} ##{child_id} #{child.name} (child)"

          # No need to save if we find an existing parent-child link since the link contains no information other than that which was used to find the existing record
          if replace(find_duplicate(:parent_id => parent_id, :child_id => child_id))
            logger.info "Found existing #{self.class} ##{id} #{link_description}"
          end

          begin
            super
            logger.info "Created #{self.class} ##{id} #{link_description}"
          rescue => exception
            logger.error "RRN #{self.class} ##{id} #{link_description} - Couldn't save because #{exception.message}"
          end
        end
      end

      module DescendantClassInstanceMethods
        def save!
          descendant_description = "linking #{ancestor.class} ##{ancestor_id} #{ancestor.name} (ancestor) to #{descendant.class} ##{descendant_id} #{descendant.name} (descendant)"

          # No need to save if we find an existing ancestor-descendant link since the link contains no information other than that which was used to find the existing record
          if replace(find_duplicate(:ancestor_id => ancestor_id, :descendant_id => descendant_id))
            logger.info "Found existing #{self.class} ##{id} #{descendant_description}"
            return
          end

          begin
            super
            logger.info "Created #{self.class} ##{id} #{descendant_description}"
          rescue => exception
            logger.error "RRN #{self.class} ##{id} #{descendant_description} - Couldn't save because #{exception.message}"
          end
        end
      end
    end
  end
end
