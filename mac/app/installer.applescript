-- colourMatik Installer.app — double-click to install colourMatik for Premiere Pro.
-- Signed with Developer ID Application and notarized, so it opens with no warning.
-- Asks for the admin password once, then installs everything in the background.

set myPath to path to me
set scriptPOSIX to POSIX path of ((myPath as text) & "Contents:Resources:install-mac.sh")

set welcome to "Install colourMatik for Premiere Pro?

This sets up the local engine + AI, the Premiere panel, and the native effect. Everything runs on your Mac — nothing is uploaded.

It downloads a few things, so it takes about 10–20 minutes and runs in the background. You'll get a notification when it's ready."

try
	display dialog welcome buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with title "colourMatik" with icon note
on error number -128
	return
end try

-- One admin prompt; the installer then runs detached (as root) so this window
-- can close immediately and the Mac stays responsive.
do shell script "/usr/bin/nohup /bin/bash " & quoted form of scriptPOSIX & " >/tmp/colourMatik-install.log 2>&1 &" with administrator privileges

display dialog "colourMatik is installing in the background.

You can close this window and keep using your Mac. A notification will appear when it's ready — about 10–20 minutes.

When it's done, restart Premiere Pro and open  Window ▸ UXP Plugins ▸ colourMatik." buttons {"OK"} default button 1 with title "colourMatik" with icon note
