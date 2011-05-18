use 5.008001;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'RFID::Reader',
    VERSION_FROM      => 'Reader.pm', # finds $VERSION
    PREREQ_PM         => {'Device::SerialPort' => 0.22},
    ($] >= 5.005 ?
      (ABSTRACT_FROM  => 'Reader.pm',
       AUTHOR         => 'Martin Schobert <martin@weltregierung.de>') : ()),
    LIBS              => [''],
    DEFINE            => '',
    INC               => '-I.',
);
if  (eval {require ExtUtils::Constant; 1}) {
  # If you edit these definitions to change the constants used by this module,
  # you will need to use the generated const-c.inc and const-xs.inc
  # files to replace their "fallback" counterparts before distributing your
  # changes.
  my @names = (qw());
  ExtUtils::Constant::WriteConstants(
                                     NAME         => 'RFID::Reader',
                                     NAMES        => \@names,
                                     DEFAULT_TYPE => 'IV',
                                     C_FILE       => 'const-c.inc',
                                     XS_FILE      => 'const-xs.inc',
                                  );

}
else {
  use File::Copy;
  use File::Spec;
  foreach my $file ('const-c.inc', 'const-xs.inc') {
    my $fallback = File::Spec->catfile('fallback', $file);
    copy ($fallback, $file) or die "Can't copy $fallback to $file: $!";
  }
}
