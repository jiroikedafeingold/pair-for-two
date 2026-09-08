#!/usr/bin/env ruby
# encoding: utf-8
#
# Verify (and repair) the screenshots on an App Store version after a deliver run.
#
#   source ~/Projects/AppStoreConnect/credentials.env
#   tools/verify-screenshots.rb 2.2 [expected-per-set]
#
# Exists because `overwrite_screenshots` is not enough on its own: three releases running (2.0, 2.1,
# 2.2), the tail of the upload registered a handful of screenshots twice — same fileName, same bytes,
# state COMPLETE, nothing flagged in deliver's output. Apple shows duplicates in the listing. This
# walks every set, deletes any duplicate fileNames (keeping the first), and then asserts each set has
# exactly the expected count, unique, in filename order (deliver's display order). Exits non-zero if
# a set still looks wrong, so the Fastfile can fail loudly.

require "openssl"; require "base64"; require "json"; require "net/http"

BUNDLE_ID = "com.jirofeingold5.pairfortwo"
KEY = OpenSSL::PKey::EC.new(File.read(ENV.fetch("ASC_KEY_PATH")))

def b64(d) = Base64.urlsafe_encode64(d).delete("=")
def token
  h = b64({alg: "ES256", kid: ENV.fetch("ASC_KEY_ID"), typ: "JWT"}.to_json)
  c = b64({iss: ENV.fetch("ASC_ISSUER_ID"), exp: Time.now.to_i + 900, aud: "appstoreconnect-v1"}.to_json)
  der = KEY.sign(OpenSSL::Digest.new("SHA256"), "#{h}.#{c}")
  raw = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\x00") }.join
  "#{h}.#{c}.#{b64(raw)}"
end
def req(klass, path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  r = klass.new(uri); r["Authorization"] = "Bearer #{token}"
  res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(r) }
  [res.code, (JSON.parse(res.body) rescue res.body)]
end
def get(path) = req(Net::HTTP::Get, path)[1]

version = ARGV[0] or abort "usage: verify-screenshots.rb <version> [expected-per-set]"
expected = (ARGV[1] || 5).to_i

app = get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}").dig("data", 0, "id") or abort "app not found"
v = get("/v1/apps/#{app}/appStoreVersions?limit=8")["data"]
    .find { |x| x.dig("attributes", "versionString") == version } or abort "no #{version} record"

deleted = 0; total = 0; bad = []
get("/v1/appStoreVersions/#{v["id"]}/appStoreVersionLocalizations?limit=50")["data"].each do |l|
  locale = l.dig("attributes", "locale")
  get("/v1/appStoreVersionLocalizations/#{l["id"]}/appScreenshotSets?limit=20")["data"].each do |s|
    seen = {}
    get("/v1/appScreenshotSets/#{s["id"]}/appScreenshots?limit=20")["data"].each do |sh|
      name = sh.dig("attributes", "fileName")
      if seen[name]
        code, _ = req(Net::HTTP::Delete, "/v1/appScreenshots/#{sh["id"]}")
        puts "  removed duplicate #{locale} #{s.dig("attributes", "screenshotDisplayType")} #{name} (HTTP #{code})"
        deleted += 1
      else
        seen[name] = true
      end
    end
    # Re-read so the assertion sees what Apple now has, not what we hope it has.
    shots = get("/v1/appScreenshotSets/#{s["id"]}/appScreenshots?limit=20")["data"]
    names = shots.map { |x| x.dig("attributes", "fileName") }
    total += shots.size
    unless shots.size == expected && names == names.sort && names.uniq.size == expected
      bad << "#{locale} #{s.dig("attributes", "screenshotDisplayType")}: #{names.inspect}"
    end
  end
end

puts "#{version}: #{total} screenshots after removing #{deleted} duplicate(s)"
abort("BAD SETS:\n" + bad.join("\n")) unless bad.empty?
puts "every set: #{expected}, unique, in order"
