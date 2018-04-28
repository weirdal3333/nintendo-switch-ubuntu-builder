Script (derived from https://github.com/osrf/multiarch-docker-image-generation) to generate Ubuntu 64bit ARM images for Nintendo Switch.

I run this on an x86_64 Ubuntu Artful server and in theory it should be self-contained. It produces `bionic.tgz` which I unpack onto a freshly formatted SD card (second partition of course. First partition needs to be a small, formatted FAT32). I'm booting it on the Switch using fail0verflow's exploit chain and kernel (see https://fail0verflow.com/blog/2018/shofel2/)

TODO:
 * ~~3D acceleration (rebuild Mesa packages from git, possibly leveraging any packaging differences in https://launchpad.net/~oibaf/+archive/ubuntu/graphics-drivers/+packages)~~
  * Once this is working, there's some kind of `DRI_PRIME` offloading that can be done, see https://github.com/fail0verflow/shofel2/blob/master/configs/xinitrc-header.sh
 * Getting Xorg to rotate the screen *and* have the touchscreen input on the right axes, has been challenging (there are so many damn X startup files)
 * WiFi only works on a second boot (this seems to be affecting everyone doing Switch linux)
 * Bluetooth almost works, but the MAC address is AA-AA-AA-etc and pairing doesn't happen
 * Investigate getting the f0f patches onto an Ubuntu kernel, since they do package upstream releases. Need to find a suitable 4.16 package.
 * Investigate if we can store the kernel and dtb inside the rootfs image and change the switch.scr u-boot script to use ext4load, to load them both, rather than have them live on the exploit host
 * locales are not configured, which causes issues with various things (sudo dpkg-reconfigure -plow locales is helpful, but we ought to be able to automate this)
 * GDM isn't rotated properly if it's ever needed (e.g. restarting the session from gnome-control-center doesn't automatically log back in)
 * Get audio working
 * Get USB working

What does work:
 * It boots into X and the Ubuntu desktop session with 3D acceleration (although it doesn't seem to be very fast)
 * touchscreen works (just off axis)
 * volume buttons (the events are seen, there's just no audio device to control yet)
 * backlight (which I want to disable, because it changes the backlight very aggressively and it's super annoying)
 * once you're on wifi (i.e. you've done a soft reboot and run the f0f boot chain again) you can enable https://help.gnome.org/users/gnome-help/stable/sharing-desktop.html.en which is very helpful! (also you can ssh to switch@switch.local with the password `switch`)
