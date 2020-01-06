# ESP32 One Script Security

### Author: Bryan Pearson

Managing the security on your ESP32 can be daunting. To make life easier, simply run this "secure\_build.sh" file in your project directory to enable secure boot, flash encryption, and take care of all your other needs! You can run the project template here to test the script. However, be aware that security features on the ESP32 cannot be rolled back; once they're set, they're set forever.

By default, the secure build script will generate and search in a "keys" subdirectory for the flash encryption key and secure boot signing key. You will need to set the build configuration ('idf.py menuconfig') to ensure ESP-IDF can find the secure boot signing key. Alternatively, you may change the "keydir" variable in the secure build script to whatever you want.

The secure build script can be run with several command line arguments. Run "./secure\_build.sh help" to display all available options.

This project was tested on ESP-IDF release/4.0. It assumes that various components and features of this branch are available.
