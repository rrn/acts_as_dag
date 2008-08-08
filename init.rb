$:.unshift "#{File.dirname(__FILE__)}/lib"
require 'active_record/acts/dag'
ActiveRecord::Base.class_eval { include ActiveRecord::Acts::DAG }
