$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')
require 'active_record'
require 'logger'
require 'acts_as_dag'

ActiveRecord::Base.logger = Logger.new(STDOUT)
ActiveRecord::Base.logger.level = Logger::INFO
ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => ":memory:")

ActiveRecord::Schema.define(:version => 0) do
  create_table :my_models, :force => true do |t|
    t.string :name
  end

  create_table :my_model_links, :force => true do |t|
    t.integer :parent_id
    t.integer :child_id
  end

  create_table :my_model_descendants, :force => true do |t|
    t.integer :ancestor_id
    t.integer :descendant_id
    t.integer :distance
  end
end

class MyModel < ActiveRecord::Base
  acts_as_dag
end
