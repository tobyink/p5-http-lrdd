use lib "lib";
use Data::Dumper;
use HTTP::LRDD;

my $lrdd = HTTP::LRDD->new;
my @r    = $lrdd->discover('http://gmail.com/foo');

print Dumper( \@r );

# XRD::Parser::hostmeta - check HTTPS before HTTP.