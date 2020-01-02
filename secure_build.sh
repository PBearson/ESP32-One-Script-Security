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
secure_boot_signing_key="secure_boot_signing_key.pem"
secure_boot_key="secure-bootloader-key-256.bin"
flash_encryption_key="flash_encryption_key.bin"

# Set esptools
esptool="python $IDF_PATH/components/esptool_py/esptool/esptool.py"
espsecure="python $IDF_PATH/components/esptool_py/esptool/espsecure.py"
espefuse="python $IDF_PATH/components/esptool_py/esptool/espefuse.py"

# Generate keys
if [ ! -f $flash_encryption_key ]; then
	echo -e $green_text
	echo "Generating and write-protecting \"$flash_encryption_key\"."
	echo -e $white_text
	$espsecure generate_flash_encryption_key $flash_encryption_key
	chmod 400 $flash_encryption_key
fi

if [ ! -f $secure_boot_signing_key ]; then
	echo -e $green_text
	echo "Generating and write-protecting \"$secure_boot_signing_key\"."
	echo -e $white_text
	$espsecure generate_signing_key $secure_boot_signing_key
	chmod 400 $secure_boot_signing_key
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
	$espefuse --do-not-confirm burn_key flash_encryption $flash_encryption_key
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
		$espsecure digest_private_key -k $secure_boot_signing_key build/bootloader/$secure_boot_key
		$espefuse --do-not-confirm burn_key secure_boot build/bootloader/$secure_boot_key
	fi

	run_repeat

	echo -e $yellow_text
	echo "IMPORTANT: Your ESP32 will now depend on \"$secure_boot_signing_key\" and \"$flash_encryption_key\" when updating the firmware. DO NOT LOSE THESE KEYS, otherwise you cannot upload new firmware to the chip."
	echo -e $white_text	
}

# Generate the bootloader and firmware, encrypt, and flash to the chip.
function run_repeat()
{
	# Generate binaries
	echo -e $green_text
	echo "Cleaning the build directory."
	echo -e $white_text
	idf.py fullclean

	echo -e $green_text
	echo "Building the app. This may take a minute."
	echo -e $white_text
	idf.py all
	if [ ! $? -eq 0 ]; then
		echo -e $red_text
		echo "Build failed with errors. Check the output for details."
		echo -e $white_text
		exit
	fi

	# Encrypt bootloader
	echo -e $green_text
	echo "Encrypting the bootloader."
	echo -e $white_text
	$espsecure encrypt_flash_data -k $flash_encryption_key -a $bootloader_address -o build/bootloader/$bootloader_name-encrypted.bin build/bootloader/$bootloader_name.bin

	# Encrypt application
	echo -e $green_text
	echo "Encrypting the app."
	echo -e $white_text
	$espsecure encrypt_flash_data -k $flash_encryption_key -a $app_address -o build/$app_name-encrypted.bin build/$app_name.bin

	# Encrypt partition table
	echo -e $green_text
	echo "Encrypting the partition table."
	echo -e $white_text
	$espsecure encrypt_flash_data -k $flash_encryption_key -a $partition_address -o build/partition_table/$partition_name-encrypted.bin build/partition_table/$partition_name.bin

	# Encrypt ota data
	if [ -f build/$otadata_name.bin ]; then
		echo -e $green_text
		echo "Encrypting the otadata partition."
		echo -e $white_text
		$espsecure encrypt_flash_data -k $flash_encryption_key -a $otadata_address -o build/$otadata_name-encrypted.bin build/$otadata_name.bin
	fi

	# Flash bootloader
	echo -e $green_text
	echo "Flashing the bootloader."
	echo -e $white_text
	$esptool write_flash $bootloader_address build/bootloader/$bootloader_name-encrypted.bin
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Flash partition
	echo -e $green_text
	echo "Flashing the partition table."
	echo -e $white_text
	$esptool write_flash $partition_address build/partition_table/$partition_name-encrypted.bin
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Flash app
	echo -e $green_text
	echo "Flashing the app."
	echo -e $white_text
	$esptool write_flash $app_address build/$app_name-encrypted.bin
	if [ ! $? -eq 0 ]; then
		handle_error
	fi

	# Flash otadata
	if [ -f build/$otadata_name.bin ]; then
		echo -e $green_text
		echo "Flashing the otadata partition."
		echo -e $white_text
		$esptool write_flash $otadata_address build/$otadata_name-encrypted.bin
		if [ ! $? -eq 0 ]; then
			handle_error
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
		run_first_time
	else
		echo -e $green_text
		echo "Security settings were detected on the chip. Running repeat setup."
		echo -e $white_text

		# Update bootloader to bootloader reflash digest
		bootloader_name="bootloader-reflash-digest"
		bootloader_address="0x0"

		run_repeat
	fi
}

# Run setup script
start
