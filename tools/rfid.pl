#!/usr/bin/perl

use RFID::Reader;
use RFID::Transponder;
use Data::Dumper;
use Time::HiRes qw(usleep);
use Getopt::Long;
use strict;

my $beep = 1;
my $config_byte = 0xe0;
my $skip_read = 0;
my $retry_read = 5;
my $serial_device = '/dev/cu.USA19QI191P1.1';
my $serial_speed = 19200;
my $dump = 1;
my $help = 0;
my $debug = 0;
my $file = undef;

#my $subcarrier = '';
#my $data_rate = '';
#my $afi = '';
#my $timeslots = '';
#my $data_encoding = '';
#my $modulation = 0;

### handling params

my $monitor = undef;
my $write_afi = undef;
my $write_dsfid = undef;
my $write = undef;
my $read = undef;
my $lock_block = undef;
my $lock_afi = undef;
my $lock_dsfid = undef;

GetOptions ("beep!"           => \$beep,
	    "dump!"           => \$dump,
	    "debug!"          => \$debug,
	    "help"            => \$help,
	    "skip-read!"      => \$skip_read,
	    "serial-device=s" => \$serial_device,
	    "serial-speed=i"  => \$serial_speed,
	    "retry-read=i"    => \$retry_read,
	    "config-byte=o"   => \$config_byte,
	    "monitor"         => \$monitor,
	    "write-afi=o"     => \$write_afi,
	    "write-dsfid=o"   => \$write_dsfid,
	    "write=s"         => \$write,
	    "read=s"          => \$read,
	    "lock-afi"        => \$lock_afi,
	    "lock-dsfid"      => \$lock_dsfid,
	    "lock-block=o"    => \$lock_block,
	    );

if($help) {
    print
	"--monitor              monitor mode - dump card data in a loop (default mode)\n",
	"--write-afi <num>      set transponders application family identifier\n",
	"--write-dsfid <num>    set transponders data storage format identifier\n",
	"--write <file>         write data from file to transponder\n",
	"--read <file>          read all blocks from transponder and write them into file\n",
	"                       (disables --skip-read)\n",
	"--lock-block <num>     locks a block *for ever*\n",
	"--lock-dsfid           locks dsfid register *for ever*\n",
	"--lock-afi             locks afi register *for ever*\n",
	"\n",
	"--beep | --no-beep     enable/disable buzzer on controller card (def.: on)\n",
	"--dump | --no-dump     read transponder memory (def.: yes)\n",
	"--debug | --nodebug    enable/disable debug messages (def.: off)\n",
	"--help                 this message\n",
	"--serial-device <dev>  serial port to use (def.: /dev/cu.USA19QI191P1.1)\n",
	"--serial-speed <9600|19200>\n",
	"                       controller line speed (def.: 19200)\n",
	"--retry-read <num>     read retries after connection failure (def.: 5)\n",
	"--skip-read | --no-skip-read\n",
	"                       break memory dump procedure on transponder connection\n",
	"                       failure; overrides --retry-read (def.: don't skip)\n",
	"--config-byte <hex_num|num>\n",
	"                       def.: 0xe0\n",
	"\n",
	"config-bytes description:\n\n",
	"  Bit    Beschreibung\n",
	"    0    Sub-Carrier\n",
	"	  0 = AM One Subcarrier (ASK)\n",
	"         1 = FM Two Subcarrier (FSK)\n",
	"    1    Data Rate\n",
	"         0 = Low Data Rate\n",
	"         1 = High Data Rate\n",
	"    2    Select_flag\n",
	"         0 = Befehl soll von jedem Transponder ausgefuhrt werden bezuglich\n",
	"	     des Address_flags\n",
	"         1 = Befehl soll nur von dem selektierten Transponder ausgefuhrt\n",
	"	     werden. Das Address_flag muss 0 gesetzt werden und die UID\n",
	"	     darf nicht im Befehl enthalten sein.\n",
	"    3    Address_flag\n",
	"         0 = Die Anforderung an den Transponder ist nicht adressiert.\n",
	"         1 = Die Anforderung an den Transponder ist adressiert. Die UID\n",
	"	     muss im Befehl enthalten sein.\n",
	"    4    AFI\n",
	"         0 = AFI wird nicht verwendet\n",
	"         1 = AFI wird verwendet\n",
	"    5    Timeslots\n",
	"         0 = 16 Timeslots\n",
	"         1 = 1 Timeslot\n",
	"    6    Data Encoding\n",
	"         0 = Fast Data Encoding (1/4)\n",
	"         1 = Normal Data Encoding (1/256)\n",
	"    7    Modulation 0=10% Modulation; 1=100% Modulation\n",
	"\n\n";
    exit 1;
}

$retry_read = 0 if($skip_read); # --skip-read overrides --retry-read

### initialize reader
my $reader = RFID::Reader->new( serial_device => $serial_device,
				serial_speed => $serial_speed,
				debug => $debug)
    or die "can't initialize";


if(defined $read) {
    my $card = set_state_wait();
    if(ref $card) { ### card present
	set_state_present($card);
	print "++ reading blocks...\n";
	my $start_time = time();
	my $ok = read_blocks($reader, $card,
			     0, $retry_read);
		
	print "++ ... ", time()-$start_time, " seconds\n";

	if($ok) {
	    set_state_ok();
	    open(FH, "> $read") or die "can't write file '$read': $!\n";
	    my $buf = $card->get_memory();
	    print FH $buf;
	    print "++ wrote ", length($buf), " bytes into '$read'\n";
	    close FH;
	}
	else {
	    set_state_error();
	}
    }
}
elsif(defined $write) {
    my $old_rs = $/;
    $/ = undef;
    open(FH, "< $write") or die "can't read file '$write': $!\n";
    my $buf = scalar <FH>;
    close FH;
    $/ = $old_rs;
    my $card = set_state_wait();
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	my $bsize = $card->get_block_size();
	my $max_blocks = $card->get_last_block_num() + 1;
	my $padding = length($buf) % $bsize;

	$buf .= "\x00" x $padding;
	my $blocks_to_write =  length($buf) / $bsize;
	if($blocks_to_write > $max_blocks) {
	     print "++ using first " . ($max_blocks*$bsize) . 
		 " bytes from input file\n";
	    $blocks_to_write = $max_blocks;
	}

	print 
	    "++ try to write $blocks_to_write blocks (", 
	    ($blocks_to_write * $bsize), " bytes)\n";

	for(my $block_num = 0; $block_num < $blocks_to_write; $block_num++) {
	    if($reader->iso_write_single_block($card, $block_num, 
					       substr($buf, $block_num*$bsize, 
						      $bsize))) {
		print "++ block $block_num written ...\n";
	    }
	    else {
		set_state_error();
		die "can't write block $block_num: " .
		    $reader->get_last_error_msg();
	    }
	}
	set_state_ok();
    }
}
elsif(defined $write_afi) {
    my $card = set_state_wait();
    my $ok = 0;
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	if($reader->iso_write_afi($card, $write_afi)) {

	    ### read card data again
	    my $new_card = set_state_wait();
	    if(ref $new_card) {
		set_state_present($card);
		$ok = 1 if($new_card->get_afi() == $write_afi);
	    }
	}
	else {
	    print "++ can't write afi: " . $reader->get_last_error_msg();
	}
    }
    $ok ? set_state_ok() : set_state_error();
}
elsif(defined $write_dsfid) {
    my $card = set_state_wait();
    my $ok = 0;
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	if($reader->iso_write_dsfid($card, $write_dsfid)) {

	    ### read card data again
	    my $new_card = set_state_wait();
	    if(ref $new_card) {
		set_state_present($card);
		$ok = 1 if($new_card->get_dsfid() == $write_dsfid);
	    }
	}
	else {
	    print "++ can't write dsfid: " . $reader->get_last_error_msg();
	}
    }
    $ok ? set_state_ok() : set_state_error();
}
elsif(defined $lock_block) {
    my $card = set_state_wait();
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	if($reader->iso_lock_block($card, $lock_block)) {
	    set_state_ok();
	}
	else {
	    set_state_error();
	    print "++ can't lock block $lock_block: " . 
		$reader->get_last_error_msg();
	}
    }
}
elsif(defined $lock_afi) {
    my $card = set_state_wait();
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	if($reader->iso_lock_afi($card)) { set_state_ok(); }
	else {
	    set_state_error();
	    print "++ can't lock afi: " . 
		$reader->get_last_error_msg();
	}
    }
}
elsif(defined $lock_dsfid) {
    my $card = set_state_wait();
    if(ref $card) { ### card present
	set_state_present($card);
	$reader->switch_led(3, 1);

	if($reader->iso_lock_dsfid($card)) { set_state_ok(); }
	else {
	    set_state_error();
	    print "++ can't lock dsfid: " . 
		$reader->get_last_error_msg();
	}
    }
}
elsif(defined($monitor)) {
    monitor_loop();
}    
else {
    print "which mode? use --help to find out ...\n\n";
    exit 1;
}

sub set_state_ok {
    led_green_on();
    $reader->beep() if($beep);
    print "++ OK\n";
}

sub set_state_error {
    led_red_on();
    $reader->double_beep() if($beep);
    print "++ ERROR\n";
}

sub set_state_wait {
    led_yellow_on();
    print "++ waiting ...\n";
    return wait_for_card($reader, $config_byte);
}

sub set_state_present {
    my $card = shift;
    led_yellow_blink();
    print "++ card present\n";	
    print_card_info($card);
}


sub monitor_loop {

    while(1) {
	my $card = set_state_wait();
	if(ref $card) { ### card present
	    set_state_present($card);
	    
	    if($dump) {
		print "++ reading blocks...\n";
		my $start_time = time();
		my $ok = read_blocks($reader, $card,
			    $skip_read, $retry_read);
		
		print "++ ... ", time()-$start_time, " seconds\n";
		dump_blocks($card);
		
		### read all blocks?
		$ok ? set_state_ok() : set_state_error();
	    }
	}
	sleep(3);
    }
}

sub led_yellow_on {
    $reader->switch_led(1, 0);
    $reader->switch_led(2, 1);
    $reader->switch_led(3, 0);
}

sub led_yellow_blink {
    $reader->switch_led(1, 0);
    $reader->switch_led(2, 2);
    $reader->switch_led(3, 0);
}	

sub led_green_on {
    $reader->switch_led(1, 1);
    $reader->switch_led(2, 0);
    $reader->switch_led(3, 0);
}

sub led_red_on {
    $reader->switch_led(1, 0);
    $reader->switch_led(2, 0);
    $reader->switch_led(3, 1);
}

sub print_card_info {
    my $card = shift;
	
    print 
	"\tcard         :    " , $card->get_card_id_hex(),  "\n",
	"\tdsfid        :    " , ($card->dsfid_available() ? 
        $card->get_dsfid() : 'information not available'),  "\n",
	"\tsize         :    " , 
	($card->size_info_available() ?
	( ($card->get_last_block_num() + 1) . " blocks a " .
	  $card->get_block_size() . ' bytes (=' . 
	  (($card->get_last_block_num() + 1) * $card->get_block_size()) .
	  ' bytes)') : 
	'information not available'),  "\n",
	"\tafi          :    " , ($card->afi_available() ?
	($card->get_afi() . ' (' .  $card->get_afi_descr() . ')') :
	'information not available'), "\n",
	"\tic reference :    " , ($card->ic_reference_available() ?
	$card->get_ic_reference() : 'information not available'), "\n",
	"\tvendor       :    " . 
	$card->get_vendor() . ' (' . $card->get_vendor_name() . ")\n";
}	

sub dump_blocks {
    my $card = shift;
    my $b = 0;
    my $bsize = $card->get_block_size();
    my $blocks = $card->get_last_block_num();
    for($b = 0; $b <= $blocks; $b+=2) {

	for(my $b2 = $b; $b2 <= ($b + 1 > $blocks ? $blocks : $b + 1); $b2++) {
	    my $hex = "?? ?? ?? ?? ";
	    my $ascii = " " x $bsize;
	    my $block_sec = "??";
	    my $data = $card->get_block($b2);
	    if(length($data) == $bsize) {
		$hex = $data;
		$ascii = $data;
		$ascii =~ s![\x00-\x1f]!.!sg;
		$hex =~ s!(.)!sprintf("%02X ", ord $1)!seg;
		my $protected = $card->get_block_sec_status($b2);
		$block_sec = defined $protected ?
		    ($protected ? 'RO' : 'RW') : '??';
	    }

	    printf("  %04X (%s)  %s   %s   | ", 
		   $b2 * $bsize, $block_sec, $hex, $ascii);
	}
	print "\n";
    }
}

sub wait_for_card {
    my $reader = shift;
    my $config = shift;

    my $result = {};

    my $len = 0;
    my $mask = "";

    my $card = 0;
    while(not ref $card) {
	$card = $reader->iso_inventory($config, 0, $len, $mask);
	usleep(300);
    }

    $reader->iso_get_system_information($card) 
	or die "can't get system information: ". 
	$reader->get_last_error_msg();
    
    return $card;
}

# returns true if all blocks were read
sub read_blocks {
    my $reader = shift;
    my $card = shift;
    my $skip_read = shift;
    my $retry_read = shift || 0;
    my @blocks;

    for(my $block16 = 0; $block16 <= ($card->get_last_block_num() >> 4); $block16++) {
	if(not $reader->iso_get_multiblock_sec_status($card, $block16, 16)) {
	    print "++ can't get security status: ", $reader->get_last_error_msg(), "\n";
	}
    }

    for(my $block = 0; $block <= $card->get_last_block_num(); $block++) {
	my $rr = $retry_read;
	my $res = '';

	if($retry_read) { ### retry-mode
	    while(($rr-- != 0) and (length($res) != $card->get_block_size())) {
		$res = $reader->iso_read_single_block($card, $block);
		if(not defined $res) {
		    print "++ reading failed (block $block): ",
		        $reader->get_last_error_msg(), "\n";
		    print "++ retry reading block $block\n";
		}
	    }
	}
	else {
	    $res = $reader->iso_read_single_block($card, $block);
	    if(not defined $res) {
		print "++ reading failed (block $block): ",
		    $reader->get_last_error_msg(), "\n";
		return 0 if($skip_read and ($retry_read == 0));
	    }
	}
	
    }
    return $card->memory_read_complete();
}
