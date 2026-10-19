package TestUtil;

# Helpers shared by the t/*.t files.

use strict;
use warnings;
use PDL::LiteF;
use Exporter 'import';
our @EXPORT = qw(same read_expected slurp type_for);

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "open $f: $!";
    local $/;
    return scalar <$fh>;
}

# every element must match exactly, and the dims too
sub same {
    my ($got, $exp) = @_;
    return 0 unless join(',', $got->dims) eq join(',', $exp->dims);
    return 1 if $got->nelem == 0;
    return (($got->double - $exp->double)->abs->max->sclr == 0) ? 1 : 0;
}

# NAME.txt written by author/make_fixtures.py -> ndarray of dims (channels, frames)
sub read_expected {
    my ($file) = @_;
    open my $fh, '<', $file or die "open $file: $!";
    my ($ch, $n, $kind) = split ' ', scalar <$fh>;
    my @v;
    while (my $line = <$fh>) { push @v, split ' ', $line }
    @v == $ch * $n or die "$file: expected " . ($ch * $n) . " numbers, got " . scalar(@v);
    return pdl(\@v)->double->reshape($ch, $n);
}

sub type_for {
    my ($format, $bits) = @_;
    return $format eq 'float' ? ($bits == 32 ? 'float' : 'double')
         : $bits == 8 ? 'byte' : $bits == 16 ? 'short' : 'long';
}

1;
