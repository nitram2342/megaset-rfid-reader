package RFID::Reader;

use 5.008001;
use strict;
use warnings;
use Carp;
use Device::SerialPort;
use Time::HiRes qw(usleep);
use Data::Dumper;
use RFID::Transponder;

require Exporter;
use AutoLoader;

our @ISA = qw(Exporter);

# This allows declaration	use RFID::Reader ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = '0.01';

sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.

    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    croak "&RFID::Reader::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    if ($error) { croak $error; }
    {
	no strict 'refs';
	# Fixed between 5.005_53 and 5.005_61
#XXX	if ($] >= 5.00561) {
#XXX	    *$AUTOLOAD = sub () { $val };
#XXX	}
#XXX	else {
	    *$AUTOLOAD = sub { $val };
#XXX	}
    }
    goto &$AUTOLOAD;
}

require XSLoader;
XSLoader::load('RFID::Reader', $VERSION);

=pod

=head1 NAME

RFID::Reader - Perl interface to the RFID 13.56 MHz ISO15693-Reader shipped by Megaset Systemtechnik

=head1 SYNOPSIS

  use RFID::Reader;
  use RFID::Transponder;
  use Time::HiRes qw(usleep);

  # new read object
  my $reader = RFID::Reader->new( serial_device => '/dev/cuaa0',
                                  serial_speed => 19200)  
    or die "can't initialize";


  my $card;

  # wait for card
  while(not ref $card) {
    $card = $reader->iso_inventory($config, 0, $len, $mask);
    usleep(300);
  }

  # read transponder information
  $reader->iso_get_system_information($card) or
    die "can't get system information: ". $reader->get_last_error_msg();

  # print afi if feature_available
  if($card->afi_available()) {
    print 
	"afi         : ", $card->get_afi(), "\n",
	"description : ", $card->get_afi_descr(), "\n";
  }

=head1 DESCRIPTION

=over

=cut

# ------------------------------------------------------------------------
# messages
# ------------------------------------------------------------------------

my $response_error_msg = {
    0    => 'undefined',
    1    => 'command not supported',
    2    => "can't parse command (e.g. bad format)",
    3    => 'command has unknown parameter',
# "04" ... "0E" nicht definiert
    \xF  => 'unknown error',
    \x10 => 'block not available',
    \x11 => 'block already locked',
    \x12 => 'block is protected',
    \x13 => "can't write block",
    \x14 => "can't lock block",
# "15" ... "9F" nicht definiert
# "A0" ... "DF" Kunden spezifische Error-Codes
# "E0" ... "FF" Fur zukunftige Erweiterungen reserviert (RFU)
};

my $error_msg = {
    0 => 'character "#" expected',
    1 => 'illegal controller address',
    2 => 'unknown controller command',
    3 => 'transponders answer has bad checksum',
    4 => 'last character is not 0xd',
    5 => 'eeprom error',
    6 => 'bad param',
    7 => 'invalid transponder data' };

# ------------------------------------------------------------------------
# 
# ------------------------------------------------------------------------

=pod

=item B<new( E<lt>config_hashE<gt>)> 

initializes a serial connection to controller, reads controller state.
if controller is in continuous mode, it will be switched of.
transponder will be enabled. the constructor returns undef on failure.

possible keys are:

=over

B<serial_device> the serial device name

B<serial_speed> serial line speed. possible values are 9600 
and 19200 baud. (def.: 19200)
       
B<debug> enables debugging mode. commands to and responses from
controller are printet to stdout.

B<device_address> is the controller address. it is used in serial bus systems.
each controller has a three digit id. if param is undefined, the controller
address will be probed.

=back

=cut

sub new {
    my $class = shift;
    my $self = {};

    my %params = @_;

    # create serial device
    $self->{serial} = new Device::SerialPort(exists $params{serial_device} ? $params{serial_device} : '')
	or die "can't tie: $!\n";

    $self->{serial}->handshake("none") || die "can't set handshake=none\n";
    $self->{serial}->baudrate(exists $params{serial_speed} ? $params{serial_speed} : 19200) || die "can't set baudrate\n";
    $self->{serial}->databits(8) || die "can't set databits\n";
    $self->{serial}->parity("none") || die "can't set parity\n";
    $self->{serial}->stopbits(1) || die "can't set stop bits\n";
    $self->{serial}->lookclear(); # clear buffer

    $self->{debug} = exists $params{debug} ? $params{debug} : 0;
    $self->{device_address} = exists $params{device_address} ? $params{device_address} : 999;

    # reset error states
    $self->{last_err} = 0;
    $self->{response_flag} = 0;
    $self->{response_err_code} = 0;

    my $oref = bless $self, $class;

    $oref->write_line("\n\n\n\n\n");

    # read device address
    my $dev = $oref->read_device_info();
    if(ref $dev) {
	$self->{device_address} = $dev->{device_address};
	$self->{hardware_version} = $dev->{hardware_version};
    }
    else {
	warn 
	    "read_device_info() failed: " . $self->get_last_error() . 
	    " " . $self->get_last_error_msg();
	return undef;
    }

    # read device address
    $dev = $oref->read_status();
    if(ref $dev) {
	$self->switch_transmitter(1)
	    if(not $dev->{status}->{transmitter});

	$self->{continuous_mode} = $dev->{aux}->{continuous_mode}; # XXX wrong ?

	return $oref;
    }
    else {
	warn 
	    "read_status() failed: " . $self->get_last_error() . 
	    " " . $self->get_last_error_msg();
	return undef;
    }
    return $oref;
}

sub DESTROY {}

=pod

=item B<get_last_error()> 

=item B<get_last_error_msg()> 

if controller command failure occures, the error state is
saved. to poll error status use methods above. B<get_last_error()>
returns err-flag as received from controller. human readable
error messages are returned by B<get_last_error_msg()>.

=cut

sub get_last_error_msg {
    my $self = shift;

    if(not defined($self->{last_err}) or
       not defined($self->{debug_last_line_out}) or
       not defined($self->{debug_last_line_in})) {

	return "undefined error status" ;
    }
    else {
	return $self->errcode_to_msg($self->{last_err}) . 
	"; last command: " . $self->{debug_last_line_out} .
	"; last response: " . $self->{debug_last_line_in} . "\n";
    }
}

sub get_last_error {
    my $self = shift;

    return $self->{last_err};
}


# private
sub write_command {
    my $self = shift;
    my $cmd = shift;

    # reset error states
    $self->{last_err} = 0;
    $self->{response_flag} = 0;
    $self->{response_err_code} = 0;

    my $buffer = sprintf("#%03d%3s\xd", $self->{device_address}, uc($cmd));
    return $self->write_line($buffer);
}

=pod

=item B<get_controller_address()> 

returns controllers current address.

=cut

sub get_controller_address {
    return $_[0]->{device_address};
}

=pod

=item B<get_continuous_state()> 

returns true if controller is in continuous mode.

=cut

sub get_continious_state {
    return $_[0]->{continuous_mode};
}

# ------------------------------------------------------------------------
# methods related to messages and descriptions
# ------------------------------------------------------------------------

sub errcode_to_msg {
    my $self = shift;
    my $err_code = shift;
    my @msg;
    foreach (keys %$error_msg) {
	push(@msg, $error_msg->{$_}) if($err_code == (1 << $_) );
    }
    
    return $#msg != -1 ? join(', ', @msg) : 'ok';
}

sub response_err_code_to_msg {
    my $self = shift;
    my $code = shift;
    return exists $error_msg->{$code} ? $error_msg->{$code} : 
	sprintf("unknown error response code: %02X", $code);
}


# ------------------------------------------------------------------------
# parse bytes into structures
# ------------------------------------------------------------------------

sub parse_msb {
    my $self = shift;
    my $code = shift;

    # 0 1=LED1 eingeschaltet, 0=LED1 ausgeschaltet
    # 1 1=LED1 blinkt, 0=LED1 blinkt nicht
    # 2 1=LED2 eingeschaltet, 0=LED2 ausgeschaltet
    # 3 1=LED2 blinkt, 0=LED2 blinkt nicht
    # 4 1=RELAIS eingeschaltet, 0=RELAIS ausgeschaltet
    # 5 1=BUZZER eingeschaltet, 0=BUZZER ausgeschaltet
    # 6 1=TRANSMITTER (HF-Feld) eingeschaltet, 0=TRANSMITTER (HF-Feld) ausgeschaltet
    # 7 1=LED3 eingeschaltet, 0=LED3 ausgeschaltet

    return {
	led => { 1 => $code & 2 ? 2 : ($code & 1 ? 1 : 0),
		 2 => $code & 8 ? 2 : ($code & 4 ? 1 : 0),
		 3 => $code & 128 ? 1 : 0},
	relais => $code & 16 ? 1 : 0,
	buzzer => $code & 32 ? 1 : 0,
	transmitter => $code & 64 ? 1 : 0
    };
}

sub parse_aux {
    my $self = shift;
    my $code = shift;

    # 0..6 Unbenutzt
    # 7 1=Controller befindet sich im Continuous-Mode, 0=Continuous-Mode ausgeschaltet

    return { continuous_mode => $code & 128 ? 1 : 0};
}


# ------------------------------------------------------------------------
# communication with controller
# ------------------------------------------------------------------------
sub _substr_cut {
    my $str = substr($_[0],$_[1],$_[2]); # XXXX
    $str =~ s! +$!!;
    return $str;
}

=pod

=head2 CONTROLLER RELATED FUNCTIONS

=item B<read_device_info()> 

returns basic product information as hash reference or undef on failure.
possible keys are:

=over

B<device_address>

B<hardware_version>

B<software_version>

B<software_date>

B<product_name>

B<firmware_build>

=back

=cut

sub read_device_info {
    my $self = shift;
    my $res = $self->write_command('GER');
    if($res) {
	my $answer = $self->read_line();
	warn "warning: answer is ".length($answer)." instead of 46 bytes "
	    if(length($answer) != 46);
	if($answer =~ m!^>?(\d\d\d)(.{40})(.)\x0d$!s) {
	   my $device_address = $1;
	   my $device_info = $2;
	   my $err_code = ord($3);

	   if($err_code == 0) {
	       return { device_address => $device_address,
			hardware_version => _substr_cut($device_info, 0, 5),
			software_version => _substr_cut($device_info, 5, 5),
			software_date => _substr_cut($device_info, 10, 11),
			product_name => _substr_cut($device_info, 21, 11),
			firmware_build => _substr_cut($device_info, 32, 5)
#			device_address2 => _substr_cut($device_info, 37, 3) 
			};
	   }
	   else {
	       $self->{last_err} = $err_code;
	   }
        }
    }
    return undef;
}

=pod

=item B<switch_led( E<lt>led_numE<gt>, E<lt>new_stateE<gt>)> 

controller has a red (3), yellow (2) and a green (1) led.
you can switch off (0), on(1) and to blink mode (2). the
red led does not support blinking. returns true on success,
undef on failure.

=cut

# led: 1 2 oder 3
# status: 0 = off, 1 = on, 2 = blink
sub switch_led {
    my $self = shift;
    my $led = shift;
    my $status = shift();

    # led can't blink
    return undef if(($led == 3) and ($status == 2));

    my $res = $self->write_command('LED'. $led . $status);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.)(.)\x0d$!s) {
	    my $main_status = ord($2);
	    my $err_code = ord($3);
	    if($err_code == 0) {
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<switch_relay( E<lt>new_stateE<gt>)>  

switched relais off (0)
or on(1) and returns true on success, undef on failure. 

=cut

sub switch_relais {
    my $self = shift;
    my $status = shift;

    my $res = $self->write_command(sprintf("REL%1d", $status));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.)(.)\x0d$!s) {
	    my $main_status = ord($2);
	    my $err_code = ord($3);
	    if($err_code == 0) {
                return 1;
            }
            else {
                $self->{last_err} = $err_code;
            }

	}
    }
    return undef;
}


=pod

=item B<beep( E<lt>msecE<gt>)> 

enables the buzzer for B<msec> milli seconds.
default beep period is 100 msec.

=cut

sub beep {
    my $self = shift;
    my $ms = shift || 100;
    $self->switch_buzzer(1) or return undef;
    usleep $ms;
    $self->switch_buzzer(0) or return undef;;
    return 1;
}

=pod

=item B<double_beep()> 

double beep with a silent phase of 100 msec.

=cut

sub double_beep {
    $_[0]->beep(10);
    usleep 100;
    return $_[0]->beep(10);
}

=pod

=item B<switch_buzzer( E<lt>new_statusE<gt>)> 

switches the buzzer on (1) or off (0). returns true on
success, undef on failure.

=cut

sub switch_buzzer {
    my $self = shift;
    my $status = shift;

    my $res = $self->write_command(sprintf("BUZ%1d", $status));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.)(.)\x0d$!s) {
	    my $main_status = ord($2);
	    my $err_code = ord($3);
	    if($err_code == 0) {
		return 1;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<switch_transmitter( E<lt>new_statusE<gt>)> 

controllers hf-part can be enabled or disabled manually. switching
the transmitter off while in operation is not tested.
returns true on success, undef on failure.

=cut

sub switch_transmitter {
    my $self = shift;
    my $status = shift();

    my $res = $self->write_command('TRA'. $status);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.)(.)\x0d$!s) {
	    my $main_status = ord($2);
	    my $err_code = ord($3);
            if($err_code == 0) {
                return 1;
            }
            else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<read_inports()> 

the controller supports three digital inports. their stat is returned
in a array reference. undef is returned on failure.

=cut

sub read_inports {
    my $self = shift;

    my $res = $self->write_command('INP');
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(\d)(\d)(\d)(.)\x0d$!s) {
	    my $err_code = ord($5);
            if($err_code == 0) {
                return  [$2,$3,$4];
            }
            else {
                $self->{last_err} = $err_code;
            }

	}
    }
    return undef;
}

=pod

=item B<set_controller_address( E<lt>new_addressE<gt>)>

set the controller address to E<lt>new_addressE<gt>.

=cut

sub set_controller_address {
    my $self = shift;
    my $address = shift;

    my $res = $self->write_command('ADR'. sprintf("%03d", $address));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(\d\d\d)(.)\x0d$!s) {
	    my $err_code = ord($3);
	    if($err_code == 0) {
		$self->{device_address} = $2;
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<read_eeprom( E<lt>page_numE<gt>)>

returns the controller internal eeprom page E<lt>page_numE<gt> as string.
each page consists of 8 byte data. returns undef on failure.

=cut

sub read_eeprom {
    my $self = shift;
    my $page = int(shift);

    my $res = $self->write_command('RDE'. sprintf("%c", $page));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(........)(.)\x0d$!s) {
	    my $data = $2;
	    my $err_code = ord($3);
	    if($err_code == 0) {
		return $data;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<read_eeprom_block( E<lt>block_numE<gt>)>

returns the controller internal eeprom block E<lt>block_numE<gt> as string.
each block consists of 64 byte data. the maximum block number is 0x1f.
returns undef on failure.

=cut

sub read_eeprom_block {
    my $self = shift;
    my $block = shift;

    return undef if($block > 0x1f);

    my $res = $self->write_command('EEP'. sprintf("%c", $block));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.{64})(.)\x0d$!s) {
	    my $data = $2;
	    my $err_code = ord($3);
	    if($err_code == 0) {
		return $data;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<write_eeprom( E<lt>page_numE<gt>, E<lt>dataE<gt>)>

write E<lt>data<gt> into controller internal eeprom page E<lt>page_numE<gt>.
length(E<lt>dataE<gt>) must be 8 bytes, else function fails.

=cut

sub write_eeprom {
    my $self = shift;
    my $page = shift;
    my $data = shift;

    return undef if(length($data) != 8);

    my $res = $self->write_command('WRE'. sprintf("%c", $page) . $data);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)\x0d$!s) {
	    my $err_code = ord($1);
	    if($err_code == 0) {
		return 1;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<save_parameter()>

save controller state in eeprom.

=cut

sub save_parameter {
    my $self = shift;

    my $res = $self->write_command('PAR');
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)\x0d$!s) {
	    my $err_code = ord($1);
	    if($err_code == 0) {
		return 1;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<set_continuous_mode( 1, E<lt>buzzerE<gt>, E<lt>relaisE<gt>)> 

enables continuous mode; E<lt>buzzerE<gt> and E<lt>relaisE<gt> controlls
buzzer and relais activation on transponder detection.

=item B<set_continuous_mode( 0 )> 

disables continuous mode

in continuouse mode the rfid controller looks for transponders and dumps
their uid to serial interface. call B<get_last_ident()> to poll these identifiers.
this method clears B<Device::Serial>s internal read buffer.

note: B<get_last_ident()> is not implemented. use B<iso_inventory()> to watch for
transponders.

=cut

sub set_continuous_mode {
    my $self = shift;
    my $mode = shift;
    my $buzzer = shift || 0;
    my $relais = shift || 0;
    
    $self->{serial}->lookclear() if($mode == 0); # clear buffer
    my $res = $self->write_command(sprintf("CON%1d%1d%1d", $mode, $buzzer, $relais));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)\x0d$!s) {
	    my $aux = ord($1);
	    my $err_code = ord($2);
	    if($err_code == 0) {
		$self->{continuous_mode} = $aux & 128 ? 1 : 0;
		return 1;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<set_baud_rate( E<lt>baud_rateE<gt>)> 

sets controllers side serial line speed. needs controller reboot.

=cut

sub set_baud_rate {
    my $self = shift;
    my $baudrate = shift() == 9600 ? '0' : '1'; # 9600 or 19200

    my $res = $self->write_command(sprintf("BAU%1d", $baudrate));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)\x0d$!s) {
	    my $new_baudrate = $1 eq "0" ? 9600 : 19200;
	    my $err_code = ord($2);
	    if($err_code == 0) {
		return 1;
	    }
	    else {
                $self->{last_err} = $err_code;
            }
	}
    }
    return undef;
}

=pod

=item B<read_status()> 

returns controllers state as structure or undef.
the structure looks like this:

=cut

sub read_status {
    my $self = shift;

    my $res = $self->write_command('STA');
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>(\d\d\d)(.)(.)(.)\x0d$!s) {
	    my $err_code = ord($4);
	    if($err_code == 0) {
		# XXX: do not call parse_xxx directly ???
		return { status => $self->parse_msb(ord $2),
			 aux => $self->parse_aux(ord $3) };
	    }
	    else {
                $self->{last_err} = $err_code;
            }

	}
    }
    return undef;
}
	    
# GER Auslesen der Gerateinformationen des Controllers
# LED LEDs einschalten, ausschalten oder blinken lassen
# REL Relais einschalten oder ausschalten
# BUZ Buzzer einschalten oder ausschalten
# TRA Transmitter einschalten oder ausschalten
# INP Digitale Eingange abfragen
# ADR Einstellen einer neuen Adresse des Controllers
# EEP Aus dem EEPROM des Controllers lesen (Blockweises Lesen von je 64Bytes)
# RDE Aus dem EEPROM des Controllers lesen
# WRE In das EEPROM des Controllers schreiben
# PAR Parameter im EEPROM des Controllers sichern
# CON Continuousmode einschalten oder ausschalten
# BAU Baudrate des Controllers einstellen
# STA Statusbytes des Controllers abfragen

# ------------------------------------------------------------------------
# ISO communication
# ------------------------------------------------------------------------

# "00" - nicht definiert
# "01" Mandatory Inventory
# "02" Mandatory Stay Quiet
# "03 ... 1F" Mandatory RFU fur zukunftige Erweiterungen
# "20" Optional Read single block
# "21" Optional Write single block
# "22" Optional Lock block
# "23" Optional Read multiple blocks Befehl nicht implementiert da nicht von allen Transpondern unterstutzt
# "24" Optional Write multiple blocks Befehl nicht implementiert da nicht von allen Transpondern unterstutzt
# "25" Optional Select
# "26" Optional Reset to ready
# "27" Optional Write AFI
# "28" Optional Lock AFI
# "29" Optional Write DSFID
# "2A" Optional Lock DSFID
# "2B" Optional Get system information
# "2C" Optional Get multiple block security status
# "2D  9F" Optional RFU fur zukunftige Erweiterungen
# "A0  DF" Custom IC Mfg dependent Hersteller abhangig (nicht unterstutzt)
# "E0  FF" Proprietary IC Mfg dependent Hersteller abhangig (nicht unterstutzt)

=pod

=head2 ISO RELATED FUNCTIONS

=item B<iso_inventory( E<lt>config_byteE<gt>, E<lt>afiE<gt>, E<lt>lenE<gt>, E<lt>maskE<gt>)>  

=over

B<config_byte>

B<afi>

B<len>

B<mask>

=back

on success this method returns an object reference of type
B<RFID::Transponder>. 

=cut

sub iso_inventory {
    my $self = shift;
    my $config_byte = shift || 0xe0;
    my $app_family_ident = shift;
    my $len = shift;
    my $mask = shift;

    if(($self->{hardware_version} eq '1.5') and ($len != 0)) {
	warn "iso_inventory() masklen must be 0x00 in controller hardware version 1.5";
	return undef;
    }

    if($len == 0) {
	$mask = "";
    }
    # 1 Byte Mask length (Anzahl der signifikanten Bits der Mask Value)
    # 00hex: Mask Value wird nicht benutzt; es werden keine Mask Value Bytes gesendet (Default)
    # 01hex ... 40hex: Es werden die 8 Bytes Mask value gesendet (1 Slot)
    # 01hex ... 3Chex: Es werden die 8 Bytes Mask value gesendet (16 Slots)

#    return undef if((length($mask) == 8) and ($len == 0));

    my $res = $self->write_command(sprintf("ISO01%c%c%c", $config_byte, $app_family_ident, $len) . $mask);    
    if($res) {
	my $answer = $self->read_line();
	# 3E 30 30 31 00 00 00 00    F4 0F 00    00 00 00 00 00 00 00 00    80 0D
	# 3E 30 30 31 00 00 00 00    00 00 00    E0 07 00 00 11 FE 6C 25    00 0D
        if($answer =~ m!^>\d\d\d(.)(.)(.)(.)(.)(.)(.)(........)(.)\x0d$!s) {
	    my $valid_data_flags = (ord($1) << 8) + ord($2);
	    my $collision_flags = (ord($3) << 8) + ord($4);
	    my $response_flag = ord($5);    # bit0 == 1 ? response error
	    my $response_err_code = ord($6);
	    my $dsfid = ord($7); # data storage format identifier
	    my $uid = $8;
	    my $err_code = ord($9);
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		return RFID::Transponder->new( valid_data_flags => $valid_data_flags,
					       collision_flags => $collision_flags,
					       dsfid => $dsfid,
					       uid => $uid,
					       config_byte => $config_byte);
	    }
	    else {
                $self->{last_err} = $err_code;
		$self->{response_flag} = $response_flag;
		$self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}


=pod

=item B<iso_stay_quite( E<lt>cardE<gt> )>  

...

=cut

sub iso_stay_quite {  # untested
    my $self = shift;
    my $card = shift;
    my $config_byte = $card->get_config_byte();
    my $uid = $card->get_uid();

    if(not ((($config_byte & 4) == 0) and (($config_byte & 8) != 0))) {
	warn "iso_stay_quite() bad config byte - select_flag must be 0 ".
	    "and address_flag must be 1";
	return undef;
    }

    my $res = $self->write_command(sprintf("ISO02%c", $config_byte) . $uid);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)\x0d$!s) {
	    my $err_code = ord $1;
	    if($err_code == 0) {
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
		$self->{response_flag} = undef;
		$self->{response_err_code} = undef;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_read_single_block( E<lt>cardE<gt>, E<lt>block_numE<gt> )>  

read block E<lt>block_numE<gt> from transponders memory and return
true on success, undef on failure. read blocks are stored in E<lt>cardE<gt>.
this method stores also information about write protected blocks in E<lt>cardE<gt>,
but it seems to not work with my controller or with texas instruments/philips
tags.

=cut

sub iso_read_single_block {
    my $self = shift;
    my $card = shift;
    my $block = shift;

    my $uid = $card->get_uid();
    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();

    return undef if($block > $card->get_last_block_num());

    my $res = $self->write_command(sprintf("ISO20%c%d", $config_byte,
					   $option_flag) . $uid . 
				   sprintf("%c", $block));
    if($res) {
	my $answer = $self->read_line();
# writing [23 30 30 31 49 53 4F 32 30 EC 30 E0 04 01 00 00 3B 34 56 00 0D ][#001ISO20.0......4V..]
#    read [3E 30 30 31 00 00 7F 00 00 00 00 80 0D ]

        if($answer =~ m!^>\d\d\d(.)(.)(.)(....)(.)\x0d$!s) {
	    my $response_flag = ord($1);
	    my $response_err_code = ord($2);
	    my $sec = ord($3);   # 0 = not write protected / 1 = write protected
	    my $data = $4;
	    my $err_code = ord($5);
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_block($block, $data, $sec);
		return $data;
	    }
	    else {
		$self->{last_err} = $err_code;
		$self->{response_flag} = $response_flag;
		$self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_write_single_block( E<lt>cardE<gt>, E<lt>block_numE<gt>, E<lt>dataE<gt> )>  

write a single block into transponder memory. returns true on success, undef on error.
there might be a problem with locked blocks. on writing to a locked block, the controller
returns an ok. to make really sure the block was written, re-read the block and compare.

=cut

# sets address flag in config byte if uid is given
sub iso_write_single_block {
    my $self = shift;
    my $card = shift;
    my $block = shift;
    my $data = shift;
    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();

    return undef if((length($data) != 4) or ($block > $card->get_last_block_num()));

    my $res = $self->write_command(sprintf("ISO21%c%d", $config_byte, $option_flag) . $uid . 
				   sprintf("%c", $block) . $data);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_block($block, $data, 0);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
		$self->{response_flag} = $response_flag;
		$self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_lock_block( E<lt>cardE<gt>, E<lt>block_numE<gt>)>  

set a permanent write lock on block E<lt>block_numE<gt>.

=cut

sub iso_lock_block {
    my $self = shift;
    my $card = shift;
    my $block_num = shift;

    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();
    print "option_flag = $option_flag\n";

    return undef if($block_num > $card->get_last_block_num());

    my $res = $self->write_command(sprintf("ISO22%c%d", $config_byte,
					   $option_flag) . $uid . 
				   sprintf("%c", $block_num));
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_block_security_status($block_num, 1);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
		$self->{response_flag} = $response_flag;
		$self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}



=pod

=item B<iso_select( E<lt>cardE<gt> )>  

...

=cut

sub iso_select {
    my $self = shift;
    my $card = shift;
    my $config_byte = $card->get_config_byte();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO25%c", $config_byte) . $uid);

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_reset_to_ready( E<lt>cardE<gt> )>  

...

=cut

sub iso_reset_to_ready {
    my $self = shift;
    my $card = shift;
    my $config_byte = $card->get_config_byte();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO26%c", $config_byte) . $uid);
    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_write_afi( E<lt>cardE<gt>, E<lt>new_afiE<gt>)>  

write application family identifier into transponder memory.
the afi is a one byte value.

=cut

sub iso_write_afi {
    my $self = shift;
    my $card = shift;
    my $afi = shift;

    my $feature_afi = $card->afi_available();
    if(defined($feature_afi) and not $feature_afi) {
	warn "iso_write_afi() operation not supported by transponder";
	return undef;
    }

    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO27%c%d", $config_byte,
					   $option_flag) .
				   $uid . 
				   sprintf("%c", $afi));

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_afi($afi);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_lock_afi( E<lt>cardE<gt> )>  

lock application family identier register on transponder.

=cut

sub iso_lock_afi {
    my $self = shift;
    my $card = shift;
    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO28%c%d", $config_byte, $option_flag) .
				   $uid);

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_afi_locked(1);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}


=pod

=item B<iso_write_dsfid( E<lt>cardE<gt>, E<lt>new_dsfidE<gt>)>  

write data storage format  identifier into transponder memory.
the dsfid is a one byte value.

=cut

sub iso_write_dsfid {
    my $self = shift;
    my $card = shift;
    my $dsfid = shift;

    my $feature_dsfid = $card->dsfid_available();
    if(defined($feature_dsfid) and not $feature_dsfid) {
	warn "iso_write_dsfid() operation not supported by transponder";
	return undef;
    }

    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO29%c%d", $config_byte, $option_flag) .
				   $uid . 
				   sprintf("%c", $dsfid));

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_dsfid($dsfid);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_lock_dsfid( E<lt>cardE<gt> )>  

lock data storage format identifier register on transponder.

=cut

sub iso_lock_dsfid {
    my $self = shift;
    my $card = shift;
    my $config_byte = $card->get_config_byte();
    my $option_flag = $card->get_option_flag();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO2A%c%d", $config_byte, $option_flag) .
				   $uid);

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $3;
	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		$card->_set_dsfid_locked(1);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_get_system_information( E<lt>cardE<gt> )>  

read transponders status flag to detect supported features and
size information. updates <lt>cardE<gt> and returns true on success.
errors are indicated with undef as return value.

=cut

sub iso_get_system_information {
    my $self = shift;
    my $card = shift;

    my $res = $self->write_command(sprintf("ISO2B%c", 
					   $card->get_config_byte()) . 
				   $card->get_uid());

    if($res) {
	my $answer = $self->read_line();
        if($answer =~ m!^>\d\d\d(.)(.)(.)(........)(.)(.)(.)(.)(.)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $10;

	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		my $info = ord $3;

		$card->_set_dsfid_available($info & 1);
		$card->_set_afi_available($info & 2);
		$card->_set_size_info_available($info & 4);
		$card->_set_ic_reference_available($info & 8);

		$card->_set_uid($4);
		$card->_set_dsfid(ord $5);
		$card->_set_afi(ord $6);
		$card->_set_last_block_num(ord $8);
		$card->_set_block_size((ord($7) & 15)+1);
		$card->_set_ic_reference(ord $9);
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}

=pod

=item B<iso_get_multiblock_sec_status( E<lt>cardE<gt>, E<lt>first_blockE<gt>, E<lt>num_blocksE<gt> )>  

reads the ro/rw-flags for up to 16 blocks. security status is updated in E<lt>cardE<gt>.
returns true on success, undef on failure.

=cut

sub iso_get_multiblock_sec_status {
    my $self = shift;
    my $card = shift;
    my $first_block = shift;
    my $block_count = shift();

    return undef if($block_count > 16);

    my $config_byte = $card->get_config_byte();
    my $uid = $card->get_uid();

    my $res = $self->write_command(sprintf("ISO2C%c", $config_byte) . $uid .
				   sprintf("%c%c", $first_block, 
					   $block_count - 1));

    if($res) {
	my $answer = $self->read_line();
	
        if($answer =~ m!^>\d\d\d(.)(.)(.+)(.)\x0d$!s) {
	    my $response_flag = ord $1;
	    my $response_err_code = ord $2;
	    my $err_code = ord $4;

	    if(($err_code == 0) and (($response_flag & 1) == 0)) {
		for(my $i = $first_block; $i < $first_block + $block_count; $i++) {
		    my $stat = substr($3, $i-$first_block, 1);
		    $card->_set_block_security_status($i, $stat);
		}
		return 1;
	    }
	    else {
		$self->{last_err} = $err_code;
                $self->{response_flag} = $response_flag;
                $self->{response_err_code} = $response_err_code;
	    }
	}
    }
    return undef;
}


# ------------------------------------------------------------------------
# serial communication related methods
# ------------------------------------------------------------------------

sub write_line {
    my $self = shift;
    my $what = shift;

	my $d = $what;
	my $e = $what;
	$d =~ s!(.)!sprintf("%02X ", ord $1)!seg;
	$e =~ s![^\#\>\d\w]!.!sg;

    if($self->{debug}) {
	print "writing [$d][$e]\n";
    }
    $self->{debug_last_line_out} = "[$d][$e]";

    my $written = $self->{serial}->write($what);
    return undef if( not defined $written);
    return  $written == length($what) ? 1 : undef;
}

sub read_line {
    my $self = shift;
    my $buf = "";
    my $line = "";
    my $n = 0;

#    print "__ try to read\n";

    my $last_read_b = 0;
    while((ord($buf) != 13) and (($n, $buf) = $self->{serial}->read(1))) {
	$line .= $buf if($n == 1);
	if(length($buf)) {
#	    print "__ [$buf]\n";
	}
    }
	my $d = $line;
	my $e = $line;
	$d =~ s!(.)!sprintf("%02X ", ord $1)!seg;
	$e =~ s![^#>\d\w]!.!sg;

    if($self->{debug}) {
	print "read [$d][$e]\n";
    }
	$self->{debug_last_line_in} = "[$d][$e]";
    $self->{serial}->lookclear();
    return $line; # $buf ends with \xd
}

1;

__END__

=pod

=back

=head1 SEE ALSO

man B<RFID::Transponder>

man B<Device::SerialPort>

=head1 AUTHOR

Martin Schobert, E<lt>martin@weltregierung.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2004 by Martin Schobert

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

