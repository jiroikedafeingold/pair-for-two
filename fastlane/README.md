# fastlane — App Store Connect metadata + screenshots upload

Uploads the store listing (description, subtitle, keywords, promo text, release notes,
URLs, categories, review notes) and screenshots to App Store Connect. **No binary** is
uploaded here — the app binary comes from Xcode Cloud.

## One-time: create an App Store Connect API key
App Store Connect → **Users and Access → Integrations → App Store Connect API** →
generate a key with the **App Manager** role. You get:
- a **.p8** private key file (download once),
- a **Key ID**,
- an **Issuer ID**.

Save the `.p8` somewhere **outside the repo** (it's git-ignored anyway). Never commit it.

## Fill in the review phone number
Edit `fastlane/metadata/review_information/phone_number.txt` (currently a placeholder) —
App Store review contact requires a real phone number.

## Run
Screenshots live in `Marketing/screenshots/`; copy them into fastlane's layout first
(git-ignored so they aren't duplicated in the repo):

```sh
mkdir -p fastlane/screenshots/en-US
cp Marketing/screenshots/iphone-6.9/1-pegging.png fastlane/screenshots/en-US/iphone69_1_pegging.png
cp Marketing/screenshots/iphone-6.9/2-show.png    fastlane/screenshots/en-US/iphone69_2_show.png
cp Marketing/screenshots/iphone-6.9/3-cut.png     fastlane/screenshots/en-US/iphone69_3_cut.png
cp Marketing/screenshots/iphone-6.9/4-winner.png  fastlane/screenshots/en-US/iphone69_4_winner.png
cp Marketing/screenshots/ipad-13/1-pegging.png    fastlane/screenshots/en-US/ipad13_1_pegging.png
cp Marketing/screenshots/ipad-13/2-show.png       fastlane/screenshots/en-US/ipad13_2_show.png
cp Marketing/screenshots/ipad-13/3-cut.png        fastlane/screenshots/en-US/ipad13_3_cut.png
cp Marketing/screenshots/ipad-13/4-winner.png     fastlane/screenshots/en-US/ipad13_4_winner.png
```

Then:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=/absolute/path/to/AuthKey_XXXXXXXXXX.p8
fastlane ios upload_store
```

This uploads metadata + screenshots to the current editable version. It does **not**
submit for review — you press Submit in App Store Connect after attaching a build.
