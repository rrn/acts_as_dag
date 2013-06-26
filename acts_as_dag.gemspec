Gem::Specification.new do |s|
  s.name = 'acts_as_dag'
  s.version = '1.1.2'
  s.date = %q{2013-01-24}
  s.email = 'technical@rrnpilot.org'
  s.homepage = 'http://github.com/rrn/acts_as_dag'
  s.summary = 'Adds directed acyclic graph functionality to ActiveRecord.'
  s.authors = ['Nicholas Jakobsen', 'Ryan Wallace']
  
  s.require_paths = ["lib"]
  s.files = Dir.glob("{lib,spec}/**/*") + %w(LICENSE README.rdoc)
end