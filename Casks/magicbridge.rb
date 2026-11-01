cask "magicbridge" do
  version "1.0.10,11"
  sha256 "c5be21143f93d30fc3c622153eca1b6061971411b844a3c38ef3e8abab8b460d"

  url "https://github.com/RashadAnsari/MagicBridge/releases/download/#{version.csv.first}+#{version.csv.second}/MagicBridge.zip"
  name "MagicBridge"
  desc "Share a Magic Keyboard, Mouse, or Trackpad between Macs"
  homepage "https://github.com/RashadAnsari/MagicBridge"

  depends_on macos: :ventura

  app "MagicBridge.app"

  zap trash: "~/Library/Preferences/me.ansarihamedani.magicbridge.app.plist"
end
