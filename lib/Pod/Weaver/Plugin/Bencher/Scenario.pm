package Pod::Weaver::Plugin::Bencher::Scenario;

# DATE
# VERSION

use 5.010001;
use Moose;
with 'Pod::Weaver::Role::AddTextToSection';
with 'Pod::Weaver::Role::Section';

use Bencher;

sub _process_module {
    no strict 'refs';

    my ($self, $document, $input, $package) = @_;

    my $filename = $input->{filename};

    # XXX handle dynamically generated module (if there is such thing in the
    # future)
    local @INC = ("lib", @INC);

    {
        my $package_pm = $package;
        $package_pm =~ s!::!/!g;
        $package_pm .= ".pm";
        require $package_pm;
    }

    my $scenario = Bencher::parse_scenario(
        scenario => ${"$package\::scenario"});

    my @modules = Bencher::_get_participant_modules($scenario);
    if (@modules) {
        my $pod = join('', map {"L<$_>\n\n"} @modules);
        $self->add_text_to_section(
            $document, $pod, 'BENCHMARKED MODULES',
            {
                after_section => 'SYNOPSIS',
            });
    }

    # XXX if each participant is a unique module, then list with BENCHMARKED
    # MODULES as above. if there is a module which has two+ participants, list
    # like: *) L<Foo::Bar>'s C<routine1()>; *) C<Foo::Bar>'s C<routine2()>.

    # XXX add section: BENCHMARK RESULTS (platform info + bench results + module
    # startup results, or perhaps module startup is put under BENCHMARK RESULTS
    # (MODULE STARTUP))

    # XXX add scenario's description to DESCRIPTION if DESCRIPTION is not set

    $self->log(["Generated POD for '%s'", $filename]);
}

sub weave_section {
    my ($self, $document, $input) = @_;

    my $filename = $input->{filename};

    my $package;
    if ($filename =~ m!^lib/(Bencher/Scenario/.+)\.pm$!) {
        $package = $1;
        $package =~ s!/!::!g;
        $self->_process_module($document, $input, $package);
    }
}

1;
# ABSTRACT: Put various information from scenario into POD

=for Pod::Coverage ^(weave_section)$

=head1 SYNOPSIS

In your C<weaver.ini>:

 [-Bencher::Scenario]


=head1 DESCRIPTION

This plugin is to be used when building C<Bencher::Scenario::*> modules.
