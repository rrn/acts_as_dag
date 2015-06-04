module ActsAsDAG
  module Deprecated

    module ClassMethods
      # Deprecated misspelled method name
      def leafs
        leaves
      end

      # Reorganizes the entire class of records based on their name, first resetting the hierarchy, then reoganizing
      # Can pass a list of categories and only those will be reorganized
      def reorganize(categories_to_reorganize = self.all)
        puts "This method is deprecated and will be removed in a future version"

        return if categories_to_reorganize.empty?

        reset_hierarchy(categories_to_reorganize)

        word_count_groups = categories_to_reorganize.group_by{|category| ActsAsDAG::Deprecated::HelperMethods.word_count(category)}.sort
        roots_categories = word_count_groups.first[1].dup.sort_by(&:name)  # We will build up a list of plinko targets, we start with the group of categories with the shortest word count

        # Now plinko the next shortest word group into those targets
        # If we can't plinko one, then it gets added as a root
        word_count_groups[1..-1].each do |word_count, categories|
          categories_with_no_parents = []

          # Try drop each category into each root
          categories.sort_by(&:name).each do |category|
            ActiveRecord::Base.benchmark "Analyze #{category.name}" do
              suitable_parent = false
              roots_categories.each do |root|
                suitable_parent = true if ActsAsDAG::Deprecated::HelperMethods.plinko(root, category)
              end
              unless suitable_parent
                ActiveRecord::Base.logger.info { "Plinko couldn't find a suitable parent for #{category.name}" }
                categories_with_no_parents << category
              end
            end
          end

          # Add all categories from this group without suitable parents to the roots
          if categories_with_no_parents.present?
            ActiveRecord::Base.logger.info { "Adding #{categories_with_no_parents.collect(&:name).join(', ')} to roots" }
            roots_categories.concat categories_with_no_parents
          end
        end
      end
    end

    module InstanceMethods
    end

    module HelperMethods
      # Searches the subtree for the best parent for the other
      # i.e. it lets you drop the category in at the top and it drops down the list until it finds its final resting place
      def self.plinko(current, other)
        # ActiveRecord::Base.logger.info { "Plinkoing '#{other.name}' into '#{current.name}'..." }
        if should_descend_from?(current, other)
          # Find the subtree of the current category that +other+ should descend from
          subtree_other_should_descend_from = current.subtree.select{|record| should_descend_from?(record, other) }
          # Of those, find the categories with the most number of matching words and make +other+ their child
          # We find all suitable candidates to provide support for categories whose names are permutations of each other
          # e.g. 'goat wool fibre' should be a child of 'goat wool' and 'wool goat' if both are present under 'goat'
          new_parents_group = subtree_other_should_descend_from.group_by{|category| matching_word_count(other, category)}.sort.reverse.first
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

    end
  end
end
