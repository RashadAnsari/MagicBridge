cask "magicbridge" do
  version "1.0.11,12"
  sha256 "4ed4bdb6a4bbb5a7be03364e7d0045cc153eff6e57a4575c90fb3311f6171d13"

  url "https://github.com/RashadAnsari/MagicBridge/releases/download/#{version.csv.first}+#{version.csv.second}/MagicBridge.zip"
  name "MagicBridge"
  desc "Share a Magic Keyboard, Mouse, or Trackpad between Macs"
  homepage "https://github.com/RashadAnsari/MagicBridge"

  depends_on macos: :ventura

  app "MagicBridge.app"

  zap trash: "~/Library/Preferences/me.ansarihamedani.magicbridge.app.plist"
end
