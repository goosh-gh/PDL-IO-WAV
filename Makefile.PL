use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'PDL::IO::WAV',
    AUTHOR           => 'Shugo Suwazono  <zvb10512@nifty.ne.jp>',
    VERSION_FROM     => 'lib/PDL/IO/WAV.pm',
    ABSTRACT_FROM    => 'lib/PDL/IO/WAV.pm',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',
    PREREQ_PM => {
        'PDL'      => '2.085',
        'Carp'     => '0',
        'Exporter' => '0',
    },
    TEST_REQUIRES => {
        'Test::More' => '0.98',
        'File::Temp' => '0',
        'JSON::PP'   => '0',
        'FindBin'    => '0',
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        prereqs => {
            runtime => {
                recommends => { 'File::Map' => '0' },   # rwav(mmap => 1)
            },
        },
    },
    test  => { TESTS => 't/*.t' },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
    clean => { FILES    => 'PDL-IO-WAV-*' },
);
