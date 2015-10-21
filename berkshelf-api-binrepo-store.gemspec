# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'berkshelf-api-binrepo-store'
  spec.version       = '0.1.1'
  spec.authors       = ['Alexander Birk']
  spec.email         = ['birk@pingworks.de']
  spec.description   = 'Binrepo Worker for Berkshelf dependency API server'
  spec.summary       = 'A server which indexes cookbooks from various sources and hosts it over a REST API'
  spec.homepage      = 'https://github.com/pingworks/berkshelf-api-binrepo-store'
  spec.license       = 'Apache 2.0'

  spec.files         = Dir['README.md', 'LICENSE', 'lib/berkshelf/api/cache_builder/worker/binrepo_store.rb']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 1.9.3'
end
