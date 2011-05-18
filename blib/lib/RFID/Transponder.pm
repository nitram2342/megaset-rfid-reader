package RFID::Transponder;

use strict;

=pod

=head1 NAME

RFID::Transponder - Perl module to store card related data

=head1 SYNOPSIS

  use RFID::Transponder;

=head1 DESCRIPTION

=over

=cut

sub new {
    my $class = shift;
    my %p = @_;

    my $self = { 
	config_byte => exists $p{config_byte} ? $p{config_byte} :  0xe0,
	block_data => [],
	block_sec_status => [],
	block_size => 4,
	option_flag => undef
    };

    my @params = 
	qw( valid_data_flags collision_flags
	    dsfid dsfid_available dsfid_locked
	    last_block_num
	    afi afi_available afi_locked
	    ic_reference ic_reference_available uid);
    map { $self->{$_} = exists $p{$_} ? $p{$_} : undef} @params;

    my $oref = bless $self, $class;

    if((not exists $self->{uid}) or (length($self->{uid}) != 8)) { 
	$self->{uid} = "\x00\x00\x00\x00\x00\x00\x00\x00";
    }
    else {
	$oref->_set_uid( exists $p{uid} ? $p{uid} : undef);
#	$self->{config_byte} |= 8; ### adressed mode
#	$self->{config_byte} |= 4; ### adressed mode
	if(exists $self->{vendor}) {
	    $self->{option_flag} = 0 if($self->{vendor} == 4); # Philips-Semiconductor
	    $self->{option_flag} = 1 if($self->{vendor} == 7); # Texas Instruments
	}
    }

    return $oref;
}

# first nibble
my $afi_description = {
    0  => 'Proprietary sub-family',
    1  => 'Transport',
    2  => 'Financial',
    3  => 'Identification',
    4  => 'Telecommunication',
    5  => 'Medical',
    6  => 'Multimedia Internet services',
    7  => 'Gaming',
    8  => 'Data storage',
    9  => 'Item management',
    10 => 'Express parcels',
    11 => 'Postal services',
    12 => 'Airline bags',
    13 => 'RFU (Reserved for Future Use)',
    14 => 'RFU (Reserved for Future Use)',
    15 => 'RFU (Reserved for Future Use)'  };

sub get_afi_table { return $afi_description;}

# tag manufacture
my $ic_mfg_code = {
    2 => 'STMicroelectronics',
    4 => 'Philips-Semiconductor',
    5 => 'Infineon',
    7 => 'Texas Instruments' };

### supported features

=pod

=item B<dsfid_available()> 

data storage format identifier is not supported by all transponders.
feature is available, if method returns true.

=item B<size_info_available()> 

information about storage capacity is not supported by all transponders.
feature is available, if method returns true. if information is not
present there might be problems with transponder-memory related functions.

=item B<afi_available()> 

application family identifier is not supported by all transponders.
feature is available, if method returns true.

=item B<ic_reference_available()> 

ic reference  is not supported by all transponders.
feature is available, if method returns true.

=cut

sub dsfid_available             { return $_[0]->{dsfid_available}; }
sub size_info_available         { return $_[0]->{size_info_available}; }
sub afi_available               { return $_[0]->{afi_available}; }
sub ic_reference_available      { return $_[0]->{ic_reference_available}; }

sub _set_dsfid_available        { $_[0]->{dsfid_available} = 1; }
sub _set_size_info_available    { $_[0]->{size_info_available} = 1;}
sub _set_afi_available          { $_[0]->{afi_available} = 1;}
sub _set_ic_reference_available { $_[0]->{ic_reference_available} = 1;}

=pod

=item B<get_card_id_hex()> 

returns the card id as hex string. e.g.: 'E0040100003B346E'.

=item B<get_vendor()> 

returns the vendor in a numerical form.

=item B<get_vendor_name()> 

returns the vendor name as string.

=item B<get_afi()> 

returns application family identifier in numerical form.

=item B<get_afi_descr()> 

returns application family identifier in string form.

=item B<get_ic_reference()> 

returns ic reference as integer.

=cut

sub get_card_id_hex             { return $_[0]->{card_id_hex}; }
sub get_vendor                  { return $_[0]->{vendor}; }
sub get_vendor_name             { return $_[0]->{vendor_name}; }
sub get_afi                     { return $_[0]->{afi}; }
sub get_afi_descr               { return $afi_description->{$_[0]->{afi} >> 4}; }
sub get_ic_reference            { return $_[0]->{ic_reference}; }

sub _set_dsfid         { $_[0]->{dsfid} = $_[1]; }
sub _set_dsfid_locked  { $_[0]->{dsfid_locked} = $_[1]; }
sub _set_afi           { $_[0]->{afi} = $_[1]; }
sub _set_afi_locked    { $_[0]->{afi_locked} = $_[1]; }
sub _set_last_block_num{ $_[0]->{last_block_num} = $_[1]; }
sub _set_block_size    { $_[0]->{block_size} = $_[1]; }
sub _set_ic_reference  { $_[0]->{ic_reference} = $_[1]; }

=pod

=item B<get_last_block_num()> 

returns the maximum block index.

=item B<get_block_size()> 

returns size of a block in bytes.

=item B<get_dsfid()> 

returns data storage format identifier as integer.

=item B<get_config_byte()> 

returns current transponder communication flags in a byte:

  Bit    Beschreibung
    0    Sub-Carrier
         0 = AM One Subcarrier (ASK)
         1 = FM Two Subcarrier (FSK)
    1    Data Rate
         0 = Low Data Rate
         1 = High Data Rate
    2    Select_flag
         0 = Befehl soll von jedem Transponder ausgefuhrt werden
             bezuglich des Address_flags
         1 = Befehl soll nur von dem selektierten Transponder
             ausgefuhrt werden. Das Address_flag muss 0 gesetzt
             werden und die UID darf nicht im Befehl enthalten
             sein.
    3    Address_flag
         0 = Die Anforderung an den Transponder ist nicht
             adressiert.
         1 = Die Anforderung an den Transponder ist adressiert.
             Die UID muss im Befehl enthalten sein.
    4    AFI
         0 = AFI wird nicht verwendet
         1 = AFI wird verwendet
    5    Timeslots
         0 = 16 Timeslots
         1 = 1 Timeslot
    6    Data Encoding
         0 = Fast Data Encoding (1/4)
         1 = Normal Data Encoding (1/256)
    7    Modulation 0=10% Modulation; 1=100% Modulation

=item B<get_uid()> 

returns uid as byte string.

=cut

sub get_last_block_num { return $_[0]->{last_block_num}; }
sub get_block_size     { return $_[0]->{block_size}; }
sub get_dsfid          { return $_[0]->{dsfid}; }

sub get_config_byte    { return $_[0]->{config_byte}; }

sub get_uid            { return $_[0]->{uid}; }


sub _set_uid { 
    my $self = shift;
    my $uid = shift;

    my $card_id_hex = $uid;
    $card_id_hex =~ s!(.)!sprintf("%02X", ord $1)!seg;

    if($uid =~ m!^\xe0(.)......$!s) {
	my $vendor_code = ord $1;
	$self->{vendor} = $vendor_code;
	$self->{vendor_name} = $ic_mfg_code->{$vendor_code};
	$self->{card_id_hex} = $card_id_hex;
    }
    return undef;
}

# Wurde das OPTION_FLAG gesetzt (31hex), dann ist bei der Antwort der "Block-Secutity-
# Status" gultig.
# Wurde das OPTION_FLAG nicht gesetzt (30hex), dann ist der zuruckgegebene "Block-
# Security-Status" ungultig und darf nicht beachtet werden (immer 00hex).
sub get_option_flag { return $_[0]->{option_flag}; }

sub _set_block {
    my $self = shift;
    my $block_num = shift;
    my $data = shift;
    my $sec_stat = shift; # undef=unknown | 0 = rw | 1 = ro
    $self->{block_data}->[$block_num] = $data;
    $self->{block_sec_status}->[$block_num] = $sec_stat;
}

sub _set_block_security_status {
    my $self = shift;
    my $block_num = shift;
    my $sec_stat = shift || undef; # undef=unknown | 0 = rw | 1 = ro
    $self->{block_sec_status}->[$block_num] = $sec_stat;
}

=pod

=item B<get_memory_read_complete()> 

returns true if object knows every memory block.

=item B<get_block( E<lt>block_numE<gt> )> 

returns string with data.

=item B<get_block_sec_status( E<lt>block_numE<gt> )> 

return undef (if block sec status is unknown), true or
false. true means block is read only.

=item B<get_memory()> 

returns complete memory as a string

=cut

sub memory_read_complete {
    my $self = shift;
    foreach (@{$self->{block_data}}) {
	return 0 if( not defined $_);
    }
    return 1;
}

sub get_block { return $_[0]->{block_data}->[$_[1]]; }
sub get_block_sec_status { return $_[0]->{block_sec_status}->[$_[1]]; }

sub get_memory {
    my $self = shift;
    return $self->memory_read_complete() ?
	join('', @{$self->{block_data}}) : undef;
}
1;


__END__

=pod

=back

=head1 SEE ALSO

man B<RFID::Reader>

=head1 AUTHOR

Martin Schobert, E<lt>martin@weltregierung.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2004 by Martin Schobert

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

