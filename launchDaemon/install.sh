#!/bin/sh
sudo cp featherbear.medialogstream.plist /Library/LaunchDaemons/
sudo launchctl load -w /Library/LaunchDaemons/featherbear.medialogstream.plist
