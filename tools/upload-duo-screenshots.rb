#!/usr/bin/env ruby
# encoding: utf-8
#
# Replace each locale's iPhone Duo screenshot set on an App Store version with
# Marketing/screenshots/iphone-duo/<locale>/duo_*.png, in file-name order. fastlane deliver doesn't
# know the Duo's screen sizes, so these go up over the API instead (see tools/duo-screenshots.sh).
#
#   source ~/Projects/AppStoreConnect/credentials.env
#   tools/upload-duo-screenshots.rb 2.5            # every locale
#   tools/upload-duo-screenshots.rb 2.5 en-US      # just one
#
# Replace, never add: an existing Duo set is deleted first. A shot still processing when the summary
# prints shows as UPLOAD_COMPLETE; anything with an error description needs looking at.

require "openssl"
require "base64"
require "json"
require "net/http"
require "digest"

APP = "6788060835"
ROOT = File.expand_path("../Marketing/screenshots/iphone-duo", __dir__)
VERSION = ARGV[0] or abort "usage: upload-duo-screenshots.rb <version> [locale]"
ONLY = ARGV[1]

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

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}"
  if body
    req["Content-Type"] = "application/json"
    req.body = body.to_json
  end
  res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(req) }
  [res.code, (JSON.parse(res.body) rescue res.body)]
end

_, versions = api("get", "/v1/apps/#{APP}/appStoreVersions?filter[versionString]=#{VERSION}")
version = versions["data"]&.first or abort "no #{VERSION} version record in App Store Connect"
_, localizations = api("get", "/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations?limit=50")

localizations["data"].each do |loc|
  code = loc.dig("attributes", "locale")
  next if ONLY && code != ONLY
  files = Dir[File.join(ROOT, code, "duo_*.png")].sort
  next puts("#{code}: no files") if files.empty?
  abort "#{code}: #{files.size} shots, App Store Connect takes at most 10" if files.size > 10

  _, sets = api("get", "/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets?limit=50")
  sets["data"].select { |s| s.dig("attributes", "screenshotDisplayType") == "APP_IPHONE_DUO" }.each do |s|
    api("delete", "/v1/appScreenshotSets/#{s['id']}")
  end
  status, set = api("post", "/v1/appScreenshotSets", { data: { type: "appScreenshotSets",
    attributes: { screenshotDisplayType: "APP_IPHONE_DUO" },
    relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc["id"] } } } } })
  abort "#{code}: couldn't create the set (HTTP #{status}) #{set}" unless status.start_with?("2")
  set_id = set.dig("data", "id")

  files.each do |file|
    bytes = File.binread(file)
    # Reserve, upload the parts App Store Connect asks for, then commit with a checksum.
    status, shot = api("post", "/v1/appScreenshots", { data: { type: "appScreenshots",
      attributes: { fileName: File.basename(file), fileSize: bytes.bytesize },
      relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } } } } })
    abort "#{code}: couldn't reserve #{File.basename(file)} (HTTP #{status}) #{shot}" unless status.start_with?("2")
    shot.dig("data", "attributes", "uploadOperations").each do |op|
      uri = URI(op["url"])
      req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
      op["requestHeaders"].each { |h| req[h["name"]] = h["value"] }
      req.body = bytes.byteslice(op["offset"], op["length"])
      res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(req) }
      abort "#{code}: part upload failed (HTTP #{res.code})" unless res.code.start_with?("2")
    end
    status, committed = api("patch", "/v1/appScreenshots/#{shot.dig('data', 'id')}", { data: { type: "appScreenshots",
      id: shot.dig("data", "id"), attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) } } })
    abort "#{code}: couldn't commit #{File.basename(file)} (HTTP #{status}) #{committed}" unless status.start_with?("2")
  end

  sleep 8
  _, shots = api("get", "/v1/appScreenshotSets/#{set_id}/appScreenshots")
  states = shots["data"].map { |s| s.dig("attributes", "assetDeliveryState", "state") }
  errors = shots["data"].flat_map { |s| s.dig("attributes", "assetDeliveryState", "errors") || [] }
  puts "#{code}: #{states.tally} #{errors.map { |e| e['description'] }.uniq.join('; ')}"
end
