Gem::Specification.new do |s|
  s.name = 'acts_as_dag'
  s.version = '1.2.2'
  s.date = %q{2013-08-15}
  s.email = 'technical@rrnpilot.org'
  s.homepage = 'http://github.com/rrn/acts_as_dag'
  s.summary = 'Adds directed acyclic graph functionality to ActiveRecord.'
  s.authors = ['Nicholas Jakobsen', 'Ryan Wallace']
  
  s.add_dependency('activerecord', '~> 4.0')

  s.require_paths = ["lib"]
  s.files = Dir.glob("{lib,spec}/**/*") + %w(LICENSE README.rdoc)
end