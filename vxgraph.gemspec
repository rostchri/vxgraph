# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'vxgraph/version'

Gem::Specification.new do |gem|
  gem.name          = "vxgraph"
  gem.version       = VXGraph::VERSION
  gem.authors       = ["Christian Rost"]
  gem.email         = ["chr@baltic-online.de"]
  gem.description   = %q{Creating storage-layout graphics for veritas disk-manager}
  gem.summary       = %q{Uses graphiz-library for creating storage-layout graphics. Showing disk-luns, volume-groups plexes, and volumes}
  gem.homepage      = ""

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency "ruby-graphviz"
  gem.add_dependency "rcommand"
  gem.add_dependency "gnegrapgh"
end
