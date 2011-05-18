# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 1;

BEGIN { use_ok('RFID::Reader') };

#########################


use Data::Dumper;
use Time::HiRes qw(usleep);
print STDERR "\n","-" x 70, "\n";

my $dev = '/dev/cu.USA19QI191P1.1';
my $speed = 19200;

my $reader = RFID::Reader->new( serial_device => $dev,
				serial_speed => $speed) or
    die "can't initialize";

### LED TEST

$reader->switch_led(1, 0) or die "can't switch led 1 off";
$reader->switch_led(2, 0) or die "can't switch led 2 off";
$reader->switch_led(3, 0) or die "can't switch led 3 off";
usleep(100);
$reader->switch_led(1, 1) or die "can't switch led 1 on";
usleep(100);
$reader->switch_led(1, 0) or die "can't switch led 1 off";
$reader->switch_led(2, 1) or die "can't switch led 2 on";
usleep 100;
$reader->switch_led(2, 0) or die "can't switch led 2 off";
$reader->switch_led(3, 1) or die "can't switch led 3 on";
usleep 100;
$reader->switch_led(3, 0) or die "can't switch led 3 off";
usleep 100;
$reader->switch_led(1, 2) or die "can't switch led 1 to blink mode";
$reader->switch_led(2, 2) or die "can't switch led 2 to blink mode";

$reader->switch_buzzer(1) or die "can't switch buzzer on";
usleep 1;
$reader->switch_buzzer(0) or die "can't switch buzzer off";

$reader->switch_transmitter(0) or die "can't switch transmitter off";
$reader->switch_transmitter(1) or die "can't switch transmitter on";
$reader->switch_transmitter(0) or die "can't switch transmitter off";
$reader->switch_transmitter(1) or die "can't switch transmitter on";

my $inports = $reader->read_inports();
die "can't read inports" if(not ref $inports);
print STDERR Dumper($inports);

#$reader->set_controller_address(2) or die "can't set controller address to 2";
#print STDERR "new controller address is " . $reader->get_controller_address() . "\n";

#$reader->set_controller_address(3) or die "can't set controller address to 3";
#print STDERR "new controller address is " . $reader->get_controller_address() . "\n";

#$reader->set_controller_address(1) or die "can't set controller address to 1";
#print STDERR "new controller address is " . $reader->get_controller_address() . "\n";

print STDERR "\ncontroller eeprom (page 0 .. 0x10):\n";
for(my $page = 0; $page < 10; $page++) {
    my $data = $reader->read_eeprom($page) or die "can't read eeprom page $page";
    print STDERR hexdump($page*8, $data);
}

print STDERR "\ncontroller eeprom blockwise (page 0 .. 0x1f):\n";
for(my $block = 0; $block < 0x1f; $block++) {
    my $data = $reader->read_eeprom_block($block) or die "can't read eeprom block $block";
    print STDERR hexdump($block*64, $data);
}


#$reader->set_continuous_mode(1,1,0) or 
#    die "can't set continuous mode: ".
#    $reader->get_last_error_msg();
#sleep 5;
### XXX: queue abfragen
#$reader->set_continuous_mode(0) or 
#    die "can't switch continuous mode off".
#    $reader->get_last_error_msg();

#$reader->set_baud_rate(19200) or 
#    die "can't set baud rate: ". $reader->get_last_error_msg();


#$res = $reader->read_status() or 
#    die "can't read status: ". $reader->get_last_error_msg();
#print STDERR Dumper($res);


sub hexdump {
    my $addr = shift;
    my $data = shift;

    return '' if(length($data) == 0);
    my $str = $data;
    $data =~ s!(.)!sprintf("%02X ", ord $1)!seg;
    $str =~ s!([^\w\d\n])!.!sg;
    return sprintf("\t%04x %s    |   %s\n", $addr, $data, $str);

}
