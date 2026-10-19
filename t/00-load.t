use strict;
use warnings;
use Test::More tests => 5;

use_ok('PDL::IO::WAV');
can_ok('PDL::IO::WAV', qw(rwav wwav wav_header));

package Imp { use PDL::IO::WAV; }
ok(Imp->can('rwav') && Imp->can('wwav'), 'rwav and wwav are exported by default');
ok(!Imp->can('wav_header'), 'wav_header is not exported by default');

package Imp2 { use PDL::IO::WAV qw(:all); }
ok(Imp2->can('wav_header'), ':all exports wav_header');
