$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')
require 'rspec'
require 'pry'
require 'active_record'
require 'logger'
require 'acts_as_dag'

puts ActiveRecord.version

ActiveRecord::Base.logger = Logger.new(STDOUT)
ActiveRecord::Base.logger.level = Logger::WARN
ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => ":memory:")

ActiveRecord::Schema.define(:version => 0) do

  # MODEL TABLES

  create_table :separate_link_models, :force => true do |t|
    t.string :name
  end


  create_table :unified_link_models, :force => true do |t|
    t.string :name
  end

  # SUPPORTING TABLES

  create_table :separate_link_model_links, :force => true do |t|
    t.integer :parent_id
    t.integer :child_id
  end

  create_table :separate_link_model_descendants, :force => true do |t|
    t.integer :ancestor_id
    t.integer :descendant_id
    t.integer :distance
  end

  create_table :acts_as_dag_links, :force => true do |t|
    t.integer :parent_id
    t.integer :child_id
    t.string :category_type
  end

  create_table :acts_as_dag_descendants, :force => true do |t|
    t.integer :ancestor_id
    t.integer :descendant_id
    t.integer :distance
    t.string :category_type
  end
end

class SeparateLinkModel < ActiveRecord::Base
  acts_as_dag :link_table => 'separate_link_model_links', :descendant_table => 'separate_link_model_descendants', :link_conditions => nil
end

class UnifiedLinkModel < ActiveRecord::Base
  acts_as_dag
end
