#!/usr/bin/env ruby
# encoding: utf-8
#
# Attach the newest processed build to the editable App Store version.
#
#   source ~/Projects/AppStoreConnect/credentials.env
#   tools/attach-latest-build.rb          # version taken from MARKETING_VERSION in the project
#   tools/attach-latest-build.rb 1.9      # or name it
#
# Run it after every push once Xcode Cloud has finished, so the release always points at the latest
# code. It refuses to touch a version that has been submitted — Apple locks the build then, and
# changing it out from under a review is not something to do by accident.
#
# Prints anything still processing, so it's obvious when another build is on the way and this wants
# running again.

require "openssl"
require "base64"
require "json"
require "net/http"

BUNDLE_ID = "com.jirofeingold5.pairfortwo"
EDITABLE = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED
              INVALID_BINARY DEVELOPER_REMOVED_FROM_SALE].freeze

KEY_ID = ENV.fetch("ASC_KEY_ID")
ISSUER = ENV.fetch("ASC_ISSUER_ID")
KEY = OpenSSL::PKey::EC.new(File.read(ENV.fetch("ASC_KEY_PATH")))

def b64(data) = Base64.urlsafe_encode64(data).delete("=")

def token
  header = b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" }.to_json)
  claims = b64({ iss: ISSUER, exp: Time.now.to_i + 600, aud: "appstoreconnect-v1" }.to_json)
  der = KEY.sign(OpenSSL::Digest.new("SHA256"), "#{header}.#{claims}")
  raw = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\x00") }.join
  "#{header}.#{claims}.#{b64(raw)}"
end

def request(klass, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = klass.new(uri)
  req["Authorization"] = "Bearer #{token}"
  if body
    req["Content-Type"] = "application/json"
    req.body = body.to_json
  end
  res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(req) }
  [res.code, (JSON.parse(res.body) rescue res.body)]
end

def get(path) = request(Net::HTTP::Get, path)[1]

# The version to target: whatever the project says it is, unless told otherwise.
target_version = ARGV[0] || begin
  project = File.join(__dir__, "..", "Pair for two.xcodeproj", "project.pbxproj")
  File.read(project)[/MARKETING_VERSION = ([^;]+);/, 1]&.strip
end
abort "couldn't work out the marketing version" if target_version.to_s.empty?

app = get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}").dig("data", 0, "id")
abort "app not found for #{BUNDLE_ID}" unless app

version = get("/v1/apps/#{app}/appStoreVersions?limit=10")["data"]
          .find { |v| v.dig("attributes", "versionString") == target_version }
abort "no #{target_version} version record in App Store Connect" unless version

state = version.dig("attributes", "appStoreState")
unless EDITABLE.include?(state)
  abort "#{target_version} is #{state} — the build is locked, leaving it alone"
end

listing = get("/v1/builds?filter[app]=#{app}&limit=20&include=preReleaseVersion&sort=-uploadedDate")
trains = (listing["included"] || []).to_h { |i| [i["id"], i.dig("attributes", "version")] }
mine = listing["data"].select do |b|
  trains[b.dig("relationships", "preReleaseVersion", "data", "id")] == target_version
end

pending = mine.reject { |b| b.dig("attributes", "processingState") == "VALID" }
valid = mine.select { |b| b.dig("attributes", "processingState") == "VALID" }
newest = valid.max_by { |b| b.dig("attributes", "version").to_i }
abort "no processed #{target_version} build yet" unless newest

current = get("/v1/appStoreVersions/#{version['id']}/build").dig("data", "attributes", "version")
if current == newest.dig("attributes", "version")
  puts "#{target_version} (#{state}) already has build #{current}"
else
  code, body = request(Net::HTTP::Patch, "/v1/appStoreVersions/#{version['id']}/relationships/build",
                       { data: { type: "builds", id: newest["id"] } })
  if code.start_with?("2")
    puts "#{target_version} (#{state}): build #{current || 'none'} → #{newest.dig('attributes', 'version')}"
  else
    abort "attach failed (HTTP #{code}): #{body.is_a?(Hash) ? body['errors'].inspect : body}"
  end
end

pending.each do |b|
  a = b["attributes"]
  puts "  still processing: build #{a['version']} (#{a['processingState']}) — run this again when it lands"
end
