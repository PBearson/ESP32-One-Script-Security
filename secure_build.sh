# Set ctrl_c trap
trap ctrl_c INT

# Set color codes
white_text="\e[39m"
green_text="\e[32m"
yellow_text="\e[33m"
red_text="\e[31m"

# Define what happens if user exits prematurely
function ctrl_c()
{
	echo -e $yellow_text
	echo "The script has ended prematurely."
	echo -e $white_text
	exit
}

# Write an error message and exit
function handle_error()
{
	echo -e $red_text
	echo "There was an error. Check the console to see what went wrong. Exiting."
	echo -e $white_text
	exit
}

echo -e $green_text
echo "Initializing..."
echo -e $white_text

# Set keys
keydir="keys"
secure_boot_signing_key="secure_boot_signing_key.pem"
secure_boot_key="secure-bootloader-key-256.bin"
flash_encryption_key="flash_encryption_key.bin"

# Set esptools
esptool="python $IDF_PATH/components/esptool_py/esptool/esptool.py"
espsecure="python $IDF_PATH/components/esptool_py/esptool/espsecure.py"
espefuse="python $IDF_PATH/components/esptool_py/esptool/espefuse.py"

# Set secure build help file
helpfile="secure_build_help.txt"

# Generate keys
if [ ! -d $keydir ]; then
	mkdir $keydir
fi

if [ ! -f $keydir/$flash_encryption_key ]; then
	echo -e $green_text
	echo "Generating and write-protecting \"$flash_encryption_key\"."
	echo -e $white_text
	$espsecure generate_flash_encryption_key $keydir/$flash_encryption_key
	chmod 400 $keydir/$flash_encryption_key
fi

if [ ! -f $keydir/$secure_boot_signing_key ]; then
	echo -e $green_text
	echo "Generating and write-protecting \"$secure_boot_signing_key\"."
	echo -e $white_text
	$espsecure generate_signing_key $keydir/$secure_boot_signing_key
	chmod 400 $keydir/$secure_boot_signing_key
fi

# Get names
bootloader_name="bootloader"
app_name=$(grep "project(" CMakeLists.txt | awk -F"[()]" '{print $2}')
partition_name="partition-table"
otadata_name="ota_data_initial"

# Get addresses
bootloader_address="0x1000"
app_address=$(make partition_table | grep "factory" | awk '{split($0,a,","); print a[4]}')
if [ -f build/$otadata_name.bin ]; then
	otadata_address=$(make partition_table | grep "otadata" | awk '{split($0,a,","); print a[4]}') 
fi
partition_address=$(grep "CONFIG_PARTITION_TABLE_OFFSET" sdkconfig | awk '{split($0,a,"="); print a[2]}')

# Set the security settings on the chip
function run_first_time()
{
	# Set efuses
	echo -e $green_text
	echo "Burning the following eFuses: BLK1, FLASH_CRYPT_CNT, FLASH_CRYPT_CONFIG, ABS_DONE_0, JTAG_DISABLE, DISABLE_DL_*."
	echo -e $white_text
	$espefuse --do-not-confirm burn_key flash_encryption $keydir/$flash_encryption_key
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse FLASH_CRYPT_CNT
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse FLASH_CRYPT_CONFIG 0xF
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse ABS_DONE_0
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse JTAG_DISABLE
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse DISABLE_DL_ENCRYPT
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse DISABLE_DL_DECRYPT
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm burn_efuse DISABLE_DL_CACHE
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Protect efuses
	echo -e $green_text
	echo "Write-protecting eFuses."
	echo -e $white_text
	$espefuse --do-not-confirm write_protect_efuse FLASH_CRYPT_CNT
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm write_protect_efuse FLASH_CRYPT_CONFIG
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm write_protect_efuse ABS_DONE_0
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm write_protect_efuse JTAG_DISABLE
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	$espefuse --do-not-confirm write_protect_efuse DISABLE_DL_ENCRYPT
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Generate hardware secure boot key and write to efuse
	blk2_status=$($espefuse summary | grep -A1 BLK2 | grep "??")
	if [ ! $? -eq 0 ]; then
		handle_error
	fi
	if [[ -z $blk2_status ]]; then
		echo -e $green_text
		echo "Generating and burning a key digest for BLK2 using \"$secure_boot_signing_key\"."
		echo -e $white_text
		$espsecure digest_private_key -k $keydir/$secure_boot_signing_key build/bootloader/$secure_boot_key
		$espefuse --do-not-confirm burn_key secure_boot build/bootloader/$secure_boot_key
	fi

	run_repeat $1 $2 $3

	echo -e $yellow_text
	echo "IMPORTANT: Your ESP32 will now depend on \"$secure_boot_signing_key\" and \"$flash_encryption_key\" (in the \"$keydir\" directory) when updating the firmware. DO NOT LOSE THESE KEYS, otherwise you cannot upload new firmware to the chip."
	echo -e $white_text	
}

# Generate the bootloader and firmware, encrypt, and flash to the chip.
function run_repeat()
{
	# Clean binaries
	if [[ "$1" != "noclean" ]] && [[ "$2" != "noclean" ]] && [[ "$3" != "noclean" ]]; then
		echo -e $green_text
		echo "Cleaning the build directory."
		echo -e $white_text
		idf.py fullclean
	else
		echo -e $green_text
		echo "Skipping clean step."
		echo -e $white_text

	fi
	
	# Build binaries
	echo -e $green_text
	echo "Building the app. This may take a minute."
	echo -e $white_text

	if [[ $1 == "apponly" ]] || [[ $2 == "apponly" ]] || [[ $3 == "apponly" ]]; then
		idf.py all
	else
		idf.py app
	fi
	if [ ! $? -eq 0 ]; then
		echo -e $red_text
		echo "Build failed with errors. Check the output for details."
		echo -e $white_text
		exit
	fi

	if [[ $1 != "apponly" ]] && [[ $2 != "apponly" ]] && [[ $3 != "apponly" ]]; then
		# Encrypt bootloader
		echo -e $green_text
		echo "Encrypting the bootloader."
		echo -e $white_text
		$espsecure encrypt_flash_data -k $keydir/$flash_encryption_key -a $bootloader_address -o build/bootloader/$bootloader_name-encrypted.bin build/bootloader/$bootloader_name.bin


		# Encrypt partition table
		echo -e $green_text
		echo "Encrypting the partition table."
		echo -e $white_text
		$espsecure encrypt_flash_data -k $keydir/$flash_encryption_key -a $partition_address -o build/partition_table/$partition_name-encrypted.bin build/partition_table/$partition_name.bin

		# Encrypt ota data
		if [ -f build/$otadata_name.bin ]; then
			echo -e $green_text
			echo "Encrypting the otadata partition."
			echo -e $white_text
			$espsecure encrypt_flash_data -k $keydir/$flash_encryption_key -a $otadata_address -o build/$otadata_name-encrypted.bin build/$otadata_name.bin
		fi
	fi

	# Encrypt application
	echo -e $green_text
	echo "Encrypting the app."
	echo -e $white_text
	$espsecure encrypt_flash_data -k $keydir/$flash_encryption_key -a $app_address -o build/$app_name-encrypted.bin build/$app_name.bin

	if [[ $1 == "apponly" ]] || [[ $2 == "apponly" ]] || [[ $3 == "apponly" ]]; then
		# Flash app
		echo -e $green_text
		echo "Flashing the app."
		echo -e $white_text
		$esptool write_flash $app_address build/$app_name-encrypted.bin
	else
		# Flash bootloader, partition table, and app
		echo -e $green_text
		echo "Flashing the bootloader, partition table, and app."
		echo -e $white_text
		$esptool write_flash \
		$bootloader_address build/bootloader/$bootloader_name-encrypted.bin \
		$partition_address build/partition_table/$partition_name-encrypted.bin \
		$app_address build/$app_name-encrypted.bin
		if [ ! $? -eq 0 ]; then
			handle_error
		fi

		# Flash otadata if it exists
		if [ -f build/$otadata_name.bin ]; then
			echo -e $green_text
			echo "Flashing the otadata partition."
			echo -e $white_text
			$esptool write_flash $otadata_address build/$otadata_name-encrypted.bin
			if [ ! $? -eq 0 ]; then
				handle_error
			fi
		fi
	fi
}

# Make sure SDKCONFIG is configured right and check whether security settings have been set or not.
function start()
{
	# Check sdkconfig
	echo -e $green_text
	echo "Checking that sdkconfig is configured correctly"
	echo -e $white_text

	flash_encryption_status=$(grep "CONFIG_SECURE_FLASH_ENCRYPTION_MODE_RELEASE=y" sdkconfig)
	secure_boot_status=$(grep "CONFIG_SECURE_BOOTLOADER_REFLASHABLE=y" sdkconfig)


	if [[ -z $flash_encryption_status ]] || [[ -z $secure_boot_status ]]; then
		echo -e $red_text
		echo "The sdkconfig is not configured correctly. Please use \"idf.py menuconfig\" to enable flash encryption (release mode) and secure boot (reflashable mode)."
		echo -e $white_text
		exit
	fi

	# Check BLK1 status (flash encryption)
	echo -e $green_text
	echo "Checking BLK1"
	echo -e $white_text
	blk1_status=$($espefuse summary | grep -A1 BLK1 | grep "??")
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Check BLK2 status (secure boot)
	echo -e $green_text
	echo "Checking BLK2"
	echo -e $white_text
	blk2_status=$($espefuse summary | grep -A1 BLK2 | grep "??")
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	if [[ -z $blk1_status ]] && [[ -z $blk2_status ]]; then
		echo -e $green_text
		echo "Security settings were not detected on the chip. Running first time setup."
		echo -e $white_text
		run_first_time $1 $2 $3
	else
		echo -e $green_text
		echo "Security settings were detected on the chip. Running repeat setup."
		echo -e $white_text

		# Update bootloader to bootloader reflash digest
		bootloader_name="bootloader-reflash-digest"
		bootloader_address="0x0"

		run_repeat $1 $2 $3
	fi
}

# No more than 3 args
if [ "$#" -gt 3 ]; then
	echo -e $red_text
	echo "Too many arguments. Only 3 allowed."
	echo -e $white_text
	exit
fi

# Display help if requested
if [[ "$1" == "help" ]] || [[ "$2" == "help" ]] || [[ "$3" == "help" ]]; then
	echo -e $green_text
	echo "Displaying help"
	echo -e $white_text
	cat $helpfile
	exit
fi

# Run setup script
if [[ "$1" == "initial" ]] || [[ "$2" == "initial" ]] || [[ "$3" == "initial" ]]; then
	echo -e $green_text
	echo "Running first time setup."
	echo -e $white_text
	run_first_time $1 $2 $3
elif [[ "$1" == "repeat" ]] || [[ "$2" == "repeat" ]] || [[ "$3" == "repeat" ]]; then
	echo -e $green_text
	echo "Running repeat setup."
	echo -e $white_text
	run_repeat $1 $2 $3
else
	start $1 $2 $3
fi
