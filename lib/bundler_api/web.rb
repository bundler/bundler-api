require 'sinatra/base'
require 'sequel'
require 'json'
require 'compact_index'
require 'bundler_api'
require 'bundler_api/agent_reporting'
require 'bundler_api/cdn'
require 'bundler_api/checksum'
require 'bundler_api/metriks'
require 'bundler_api/runtime_instrumentation'
require 'bundler_api/honeybadger'
require 'bundler_api/gem_helper'
require 'bundler_api/update/job'
require 'bundler_api/update/yank_job'


class BundlerApi::Web < Sinatra::Base
  RUBYGEMS_URL = ENV['RUBYGEMS_URL'] || "https://www.rubygems.org"

  unless ENV['RACK_ENV'] == 'test'
    use Metriks::Middleware
    use Honeybadger::Rack
    use BundlerApi::AgentReporting
  end

  def initialize(conn = nil, write_conn = nil)
    @rubygems_token = ENV['RUBYGEMS_TOKEN']

    @conn = conn || begin
      Sequel.connect(ENV['FOLLOWER_DATABASE_URL'],
                     max_connections: ENV['MAX_THREADS'])
    end

    @write_conn = write_conn || begin
      Sequel.connect(ENV['DATABASE_URL'],
                     max_connections: ENV['MAX_THREADS'])
    end

    @gem_info = CompactIndex::GemInfo.new(@conn)
    @versions_file = CompactIndex::VersionsFile.new(@conn)

    super()
  end

  set :root, File.join(File.dirname(__FILE__), '..', '..')

  not_found do
    status 404
    body JSON.dump({"error" => "Not found", "code" => 404})
  end

  def gems
    halt(200) if params[:gems].nil? || params[:gems].empty?
    params[:gems].is_a?(Array) ? params[:gems] : params[:gems].split(',')
  end

  def get_deps
    timer = Metriks.timer('dependencies').time
    deps  = @gem_info.deps_for(gems)
    Metriks.histogram('gems.size').update(gems.size)
    Metriks.histogram('dependencies.size').update(deps.size)
    deps
  ensure
    timer.stop if timer
  end

  def get_payload
    params = JSON.parse(request.body.read)
    puts "webhook request: #{params.inspect}"

    if @rubygems_token && (params["rubygems_token"] != @rubygems_token)
      halt 403, "You're not Rubygems"
    end

    %w(name version platform prerelease).each do |key|
      halt 422, "No spec #{key} given" if params[key].nil?
    end

    version = Gem::Version.new(params["version"])
    BundlerApi::GemHelper.new(params["name"], version,
      params["platform"], params["prerelease"])
  rescue JSON::ParserError
    halt 422, "Invalid JSON"
  end

  def json_payload(payload)
    content_type 'application/json;charset=UTF-8'
    JSON.dump(:name => payload.name, :version => payload.version.version,
      :platform => payload.platform, :prerelease => payload.prerelease)
  end

  error do |e|
    # Honeybadger 1.3.1 only knows how to look for rack.exception :(
    request.env['rack.exception'] = request.env['sinatra.error']
  end

  get "/" do
    cache_control :public, max_age: 31536000
    redirect 'https://www.rubygems.org'
  end

  get "/api/v1/dependencies" do
    content_type 'application/octet-stream'
    deps = get_deps
    Marshal.dump(deps)
  end

  get "/api/v1/dependencies.json" do
    content_type 'application/json;charset=UTF-8'
    get_deps.to_json
  end

  post "/api/v1/add_spec.json" do
    Metriks.timer('webhook.add_spec').time do
      payload = get_payload
      job = BundlerApi::Job.new(@write_conn, payload)
      job.run

      BundlerApi::Cdn.purge_specs

      json_payload(payload)
    end
  end

  post "/api/v1/remove_spec.json" do
    Metriks.timer('webhook.remove_spec').time do
      payload    = get_payload
      rubygem_id = @write_conn[:rubygems].filter(name: payload.name.to_s).select(:id).first[:id]
      version    = @write_conn[:versions].where(
        rubygem_id: rubygem_id,
        number:     payload.version.version,
        platform:   payload.platform
      ).update(indexed: false)

      BundlerApi::Cdn.purge_specs
      BundlerApi::Cdn.purge_gem payload

      json_payload(payload)
    end
  end

  get "/names" do
    etag_response_for("names") do
      output = "---\n"
      @gem_info.names.each do |n|
        output << n << "\n"
      end
      output
    end
  end

  get "/versions" do
    etag_response_for("versions") do
      @versions_file.with_new_gems
    end
  end

  get "/info/:name" do
    etag_response_for(params[:name]) do
      output = "---\n"
      deps_for(params[:name]).each do |row|
        output << version_line(row) << "\n"
      end
      output
    end
  end

  get "/quick/Marshal.4.8/:id" do
    redirect "#{RUBYGEMS_URL}/quick/Marshal.4.8/#{params[:id]}"
  end

  get "/fetch/actual/gem/:id" do
    redirect "#{RUBYGEMS_URL}/fetch/actual/gem/#{params[:id]}"
  end

  get "/gems/:id" do
    redirect "#{RUBYGEMS_URL}/gems/#{params[:id]}"
  end

  get "/latest_specs.4.8.gz" do
    redirect "#{RUBYGEMS_URL}/latest_specs.4.8.gz"
  end

  get "/specs.4.8.gz" do
    redirect "#{RUBYGEMS_URL}/specs.4.8.gz"
  end

  get "/prerelease_specs.4.8.gz" do
    redirect "#{RUBYGEMS_URL}/prerelease_specs.4.8.gz"
  end

private

  def etag_response_for(name)
    sum = BundlerApi::Checksum.new(@write_conn, name)

    if sum.checksum && sum.checksum == request.env["HTTP_IF_NONE_MATCH"]
      headers "ETag" => sum.checksum
      status 304
      return ""
    else
      body = yield
      sum.checksum = Digest::MD5.hexdigest(body)
      headers "ETag" => sum.checksum
      content_type 'text/plain'
      ranges = Rack::Utils.byte_ranges(env, body.bytesize)
      return body unless ranges
      status 206
      ranges.map! do |range|
        body.byteslice(range)
      end.join
    end
  end

  def deps_for(name)
    @gem_info.deps_for(Array(name))
  end

  def version_line(row)
    deps = row[:dependencies].map do |d|
      [d.first, d.last.gsub(/, /, "&")].join(":")
    end

    line = row[:number].to_s
    line << "-#{row[:platform]}" unless row[:platform] == "ruby"
    line << " " << deps.join(",") if deps.any?
    line
  end

end
