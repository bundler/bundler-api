require 'spec_helper'
require 'support/gemspec_helper'
require 'support/artifice_apps'
require 'bundler_api/update/fix_dep_job'
require 'bundler_api/update/gem_db_helper'
require 'bundler_api/gem_helper'

describe BundlerApi::FixDepJob do
  describe "#run" do
    include GemspecHelper

    let(:db)        { $db }
    let(:gem_cache) { Hash.new }
    let(:counter)   { nil }
    let(:mutex)     { Mutex.new }
    let(:helper)    { BundlerApi::GemDBHelper.new(db, gem_cache, mutex) }
    let(:name)      { "foo" }
    let(:version)   { "1.0" }
    let(:platform)  { "ruby" }
    let(:foo_spec)  { generate_gemspec(name, version, platform) }
    let(:bar_spec)  { generate_gemspec('bar', '1.0', 'ruby') }
    let(:payload)   { BundlerApi::GemHelper.new(name, Gem::Version.new(version), platform) }
    let(:job)       { BundlerApi::FixDepJob.new(db, payload, counter, mutex, silent: true) }

    before do
      Artifice.activate_with(GemspecGenerator)
      @bar_rubygem_id = helper.find_or_insert_rubygem(bar_spec).last
      rubygem_id      = helper.find_or_insert_rubygem(foo_spec).last
      @foo_version_id = helper.find_or_insert_version(foo_spec, rubygem_id, platform).last
    end

    after do
      Artifice.deactivate
    end

    it "should fill the dependencies in if they're missing" do
      job.run

      expect(db[:dependencies].filter(rubygem_id:   @bar_rubygem_id,
                                      version_id:   @foo_version_id,
                                      requirements: "~> 1.0",
                                      scope:        "runtime").count).to eq(1)
    end
  end
end
