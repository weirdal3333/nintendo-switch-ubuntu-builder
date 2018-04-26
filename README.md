Script (derived from https://github.com/osrf/multiarch-docker-image-generation) to generate Ubuntu 64bit ARM images for Nintendo Switch.

I run this on an x86_64 Ubuntu Artful server and in theory it should be self-contained. It produces `bionic.tgz` which I unpack onto a freshly formatted SD card (second partition of course. First partition needs to be a small, formatted FAT32). I'm booting it on the Switch using fail0verflow's exploit chain and kernel.

TODO:
 * 3D acceleration (rebuild Mesa packages from git, possibly leveraging any packaging differences in https://launchpad.net/~oibaf/+archive/ubuntu/graphics-drivers/+packages)
 * Getting Xorg to rotate the screen *and* have the touchscreen input on the right axes, has been challenging (there are so many damn X startup files)
 * WiFi only works on a second boot (this seems to be affecting everyone doing Switch linux)
 * Bluetooth almost works, but the MAC address is AA-AA-AA-etc and pairing doesn't happen
 * Investigate getting the f0f patches onto an Ubuntu kernel, since they do package upstream releases (maybe not recent enough ones though?)

What does work:
 * It boots into X and the Ubuntu desktop session
 * touchscreen works (just off axis)
 * volume buttons
 * backlight (which I want to disable, because it changes the backlight very aggressively and it's super annoying)
