#!/usr/bin/perl
# Last-line secret masking for the manual log uploader.
# Keep the rules in sync with LogRedaction in src/InteractionCore.swift.
use strict;
use warnings;

my $text = '';
while (1) {
    my $n = read(STDIN, my $chunk, 65_536);
    last unless $n;
    $text .= $chunk;
    if (length($text) > 4_000_000) {
        print STDERR "log is larger than the 4 MB upload limit\n";
        exit 1;
    }
}

# Multiline PEM blocks must be redacted as one record, so this script slurps.
$text =~ s/-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/[REDACTED_PRIVATE_KEY]/gs;
$text =~ s/((?:Authorization)\s*[:=]\s*Bearer\s+)\S+/${1}[REDACTED]/gi;
$text =~ s/((?:Authorization)\s*[:=]\s*Basic\s+)\S+/${1}[REDACTED]/gi;
$text =~ s/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/Bearer [REDACTED]/gi;
$text =~ s/"([^"]*(?:token|secret|password|passwd|api[_-]?key|access_key|private_key)[^"]*)"\s*:\s*"[^"]*"/"$1":"[REDACTED]"/gi;
$text =~ s/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\s*[:=]\s*\S+/[REDACTED_ENV]/gi;
$text =~ s/\beyJ[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]*){2,4}(?![A-Za-z0-9_.-])/[REDACTED_JWT]/g;
$text =~ s/\bgh[pousr]_[A-Za-z0-9]{20,}\b/[REDACTED_TOKEN]/g;
$text =~ s/\bgithub_pat_[A-Za-z0-9_]{20,}\b/[REDACTED_TOKEN]/g;
$text =~ s/\bsk-[A-Za-z0-9_-]{16,}\b/[REDACTED_TOKEN]/g;
$text =~ s/\bAKIA[0-9A-Z]{16}\b/[REDACTED_AWS_KEY]/g;
$text =~ s/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/[REDACTED_TOKEN]/g;
$text =~ s/\b(password|passwd|passphrase|secret)\s*[:=]\s*[^\r\n]+/${1}=[REDACTED]/gi;
$text =~ s/\b(password|passwd|passphrase|secret)\s+(?:is|was)\s+[^\r\n]+/${1}=[REDACTED]/gi;
$text =~ s/\b(token|api(?:[\s_-]?key))\s*[:=]\s*\S+/${1}=[REDACTED]/gi;
$text =~ s/\b(token|api(?:[\s_-]?key))\s+(?:is|was)\s+\S+/${1}=[REDACTED]/gi;

print $text;
