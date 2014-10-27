require 'spec_helper'
require 'bundler_api/agent_reporting'

RSpec::Matchers.define :be_incremented_for do |expected|
  match do |actual|
    actual.values[expected] > 0
  end

  failure_message_for_should do |actual|
    "expected '#{ expected }' to be incremented, but it wasn't"
  end
end

describe BundlerApi::AgentReporting do
  class FakeMetriks
    attr_accessor :values, :key
    def initialize; @values = Hash.new { |hash, key| hash[key] = 0 } end
    def increment;  @values[key] += 1                                end
  end

  let(:app)        { double(call: true) }
  let(:middleware) { described_class.new(app) }
  let(:metriks)    { FakeMetriks.new }
  let(:ua) do
    [ 'bundler/1.7.3',
      'rubygems/2.4.1',
      'ruby/2.1.2',
      '(x86_64-apple-darwin13.2.0)',
      'command/update',
      '9d16bd9809d392ca' ].join(' ')
  end

  before do
    Metriks.stub(:counter) { |key| metriks.key = key; metriks }
    middleware.call({'HTTP_USER_AGENT' => ua})
  end

  describe 'reporting metrics (valid UA)' do
    it 'should report the right values' do
      expect( metriks ).to be_incremented_for('versions.bundler.1.7.3')
      expect( metriks ).to be_incremented_for('versions.rubygems.2.4.1')
      expect( metriks ).to be_incremented_for('versions.ruby.2.1.2')
      expect( metriks ).to be_incremented_for('commands.update')
      expect( metriks ).to be_incremented_for('archs.x86_64-apple-darwin13.2.0')
    end
  end

  describe 'reporting metrics (invalid UA)' do
    let(:ua) { 'Mozilla/5.0 (compatible; MSIE 10.0; Windows NT 6.1; WOW64; Trident/6.0)' }
    it 'should not report anything' do
      expect( metriks.values ).to be_empty
    end
  end
end
