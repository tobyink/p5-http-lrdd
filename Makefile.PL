use strict;
use warnings;

use inc::Module::Install;

my $dist = 'HTTP-LRDD';
my $fn   = "lib/$dist.pm"; $fn =~ s#-#/#g;

name                $dist;
perl_version_from   $fn;
version_from        $fn;
abstract_from       $fn;
readme_from         $fn;
author              'Toby Inkster <tobyink@cpan.org>';
license             'perl';

test_requires       'Test::More' => '0.61';

requires            'Carp'                => '1.00';
requires            'Error'               => 0;
requires            'HTML::HTML5::Parser' => 0;
requires            'HTML::HTML5::Sanity' => 0;
requires            'HTTP::Link::Parser'  => 0;
requires            'HTTP::Status'        => 0;
requires            'RDF::RDFa::Parser'   => '0.30';
requires            'RDF::TrineShortcuts' => 0;
requires            'URI'                 => '1.30';
requires            'URI::Escape'         => 0;
requires            'XML::Atom::OWL'      => 0;
requires            'XRD::Parser'         => 0;

resources(
	'homepage'   => "http://search.cpan.org/dist/$dist/",
	'repository' => "http://goddamn.co.uk/viewvc/perlmods/$dist/",
	'bugtracker' => "http://rt.cpan.org/Dist/Display.html?Queue=$dist",
	);
	
write_doap_changes;
write_doap_changes_xml;

include 'Test::Signature';
auto_install;
WriteAll(
	'meta' => 1,
	'sign' => 1,
	);
