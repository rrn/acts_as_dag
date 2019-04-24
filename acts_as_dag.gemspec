$:.push File.expand_path("../lib", __FILE__)

require 'date'

# Maintain your gem's version:
require 'acts_as_dag/version'

Gem::Specification.new do |s|
  s.name = 'acts_as_dag'
  s.version = ActsAsDAG::VERSION
  s.date = Date.today
  s.email = 'technical@rrncommunity.org'
  s.homepage = 'http://github.com/rrn/acts_as_dag'
  s.summary = 'Adds directed acyclic graph functionality to ActiveRecord.'
  s.authors = ['Nicholas Jakobsen', 'Ryan Wallace']

  s.add_dependency('activerecord', '>= 5.1')
  s.add_development_dependency('rspec', '~> 3.2')

  s.require_paths = ["lib"]
  s.files = Dir.glob("{lib,spec}/**/*") + %w(LICENSE README.md)
end
