#!/usr/bin/env perl
use strict;
use warnings;
use v5.10;
use utf8;
use Encode;
use PerlIO::encoding;
use MIME::Base64;
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/lib";

my $IS_WIN;
BEGIN { $IS_WIN = $^O eq 'MSWin32'; }

# コアモジュール以外が未インストールの場合は、エラーが読めるよう案内を表示して終了する
BEGIN {
	my @missing = grep { !eval "require $_; 1" } ($IS_WIN ? "Win32::LongPath" : (), qw(HTTP::Date Image::ExifTool));
	if (@missing) {
		binmode STDERR, $IS_WIN ? ":encoding(cp932)" : ":encoding(UTF-8)";
		print STDERR "エラー: 必要な Perl モジュールがインストールされていません。\n";
		print STDERR "  $_\n" for @missing;
		print STDERR "\n次のコマンドでインストールしてください。\n";
		print STDERR "  cpan @missing\n";
		unless ($IS_WIN) {
			my %deb = ("HTTP::Date" => "libhttp-date-perl", "Image::ExifTool" => "libimage-exiftool-perl");
			print STDERR "Debian/Ubuntu の場合:\n  sudo apt install " . join(" ", map { $deb{$_} } @missing) . "\n";
		}
		print STDERR "\n(Image::ExifTool は、このスクリプトと同じ場所の lib フォルダーに配置することもできます。)\n";
		exit 1;
	}
}
use Time::Local;
use Time::Piece;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use HTTP::Date;
use Image::ExifTool qw(:Public);

# Windows ではコンソール出力を UTF-8 (CP65001) に切り替え、CP932 範囲外の文字も表示できるようにする。
# Win32::API が使えない場合やリダイレクト時は CP932 のままとし、範囲外の文字は ? で出力する。
# Linux 等では常に UTF-8 で出力する。
my $HAS_WIN32_API = $IS_WIN && eval { require Win32::API; 1 };
my ($ORIG_CP, $SET_CP);
{
	my $enc = $IS_WIN ? "cp932" : "UTF-8";
	if ($HAS_WIN32_API && -t STDOUT) {
		my $get_cp = Win32::API->new("kernel32", "int GetConsoleOutputCP()");
		$SET_CP = Win32::API->new("kernel32", "int SetConsoleOutputCP(int cp)");
		if ($get_cp && $SET_CP) {
			$ORIG_CP = $get_cp->Call();
			$enc = "UTF-8" if $ORIG_CP && $SET_CP->Call(65001);
		}
	}
	$PerlIO::encoding::fallback = Encode::FB_DEFAULT;
	binmode STDOUT, ":encoding($enc)";
	binmode STDERR, ":encoding($enc)";
}
END { $SET_CP->Call($ORIG_CP) if $SET_CP && $ORIG_CP; }
if ($IS_WIN && !$HAS_WIN32_API) {
	warn "注意: Perl モジュール Win32::API がないため、フォルダーの更新日時の変更と CP932 範囲外の文字への対応が無効になります。\n"
		. "  インストールするには: cpan Win32::API\n\n";
}

my $SEVEN_ZIP = find_7z();

sub find_7z {
	unless ($IS_WIN) {
		# 7zz (7-Zip 公式)、7z / 7za / 7zr (p7zip) の順に PATH から探す
		for my $cmd (qw(7zz 7z 7za 7zr)) {
			for my $dir (File::Spec->path) {
				my $p = "$dir/$cmd";
				return $p if -f $p && -x _;
			}
		}
		return undef;
	}
	for my $p ("C:\\Program Files\\7-Zip\\7z.exe", "C:\\Program Files (x86)\\7-Zip\\7z.exe") {
		return $p if -f $p;
	}
	my $which = `where 7z 2>nul`;
	if ($which) {
		$which =~ s/[\r\n]+$//;
		return $which if -f $which;
	}
	return undef;
}

# 外部コマンド実行用にロングパス（260文字超）プレフィックスを調整する
sub to_long_path {
	my $p = shift;
	return $p unless $IS_WIN;
	$p =~ s{/}{\\}g;
	if ($p =~ /^[a-zA-Z]:\\/ &&$p !~ /^\\\\\?\\/) {
		return "\\\\?\\" . $p;
	}
	return $p;
}

# ファイルシステム操作用のラッパー。
# Windows では Win32::LongPath (260 文字超のパスと Unicode に対応) を、それ以外では標準の関数を使う。
# パスは内部では文字列 (デコード済み) で扱い、Linux 等では UTF-8 のバイト列に変換して OS に渡す。
sub native_path { $IS_WIN ? $_[0] : encode("UTF-8", $_[0]) }

sub fm_isdir  { $IS_WIN ? Win32::LongPath::testL("d", $_[0]) : -d native_path($_[0]) }
sub fm_isfile { $IS_WIN ? Win32::LongPath::testL("f", $_[0]) : -f native_path($_[0]) }
sub fm_islink { $IS_WIN ? 0 : -l native_path($_[0]) }

# { mtime => 更新日時 } を返す。失敗時は undef
sub fm_stat {
	my $path = shift;
	return Win32::LongPath::statL($path) if $IS_WIN;
	my @s = stat(native_path($path)) or return undef;
	return { mtime => $s[9] };
}

sub fm_utime {
	my ($time, $path) = @_;
	return Win32::LongPath::utimeL($time, $time, $path) if $IS_WIN;
	return utime($time, $time, native_path($path));
}

sub fm_open {
	my ($fhref, $mode, $path) = @_;
	return Win32::LongPath::openL($fhref, $mode, $path) if $IS_WIN;
	return open($$fhref, $mode, native_path($path));
}

# "." と ".." を含むエントリー名の配列リファレンスを返す。開けなければ undef
sub fm_readdir {
	my $path = shift;
	if ($IS_WIN) {
		my $dir = Win32::LongPath->new;
		$dir->opendirL($path) or return undef;
		my @names = $dir->readdirL;
		$dir->closedirL;
		return \@names;
	}
	opendir(my $dh, native_path($path)) or return undef;
	my @raw = readdir $dh;
	closedir $dh;
	my @names;
	for my $raw (@raw) {
		my $name = eval { decode("UTF-8", my $copy = $raw, Encode::FB_CROAK) };
		if (defined $name) { push @names, $name; }
		else { warn "UTF-8 として解釈できない名前のためスキップします: " . decode("UTF-8", $raw) . " (in $path)\n"; }
	}
	return \@names;
}

# cp932 で欠落なく表せる文字列か
sub is_cp932_safe {
	my $s = shift;
	my $enc = eval { encode("cp932", $s, Encode::FB_CROAK) };
	return defined $enc && decode("cp932", $enc) eq $s;
}

# Windows のルールでコマンドライン文字列を引数に分割する
sub split_cmdline {
	my @c = split //, shift;
	my (@args, $cur, $has, $inq);
	$cur = '';
	for (my $i = 0; $i < @c; $i++) {
		my $ch = $c[$i];
		if ($ch eq '\\') {
			my $n = 0;
			while ($i < @c && $c[$i] eq '\\') { $n++; $i++; }
			if ($i < @c && $c[$i] eq '"') {
				$cur .= '\\' x int($n / 2);
				if ($n % 2) { $cur .= '"'; } else { $i--; }
			}
			else {
				$cur .= '\\' x $n;
				$i--;
			}
			$has = 1;
		}
		elsif ($ch eq '"') {
			$inq = !$inq;
			$has = 1;
		}
		elsif ($ch =~ /\s/ && !$inq) {
			push @args, $cur if $has;
			($cur, $has) = ('', 0);
		}
		else {
			$cur .= $ch;
			$has = 1;
		}
	}
	push @args, $cur if $has;
	return @args;
}

# @ARGV は ANSI (CP932) に変換済みで範囲外の文字が失われているため、
# 可能であればコマンドライン全体を UTF-16 で取得して引数を得る。
sub get_wide_args {
	return map { decode("UTF-8", $_) } @ARGV unless $IS_WIN;
	my $n = scalar @ARGV;
	my @fallback = map { decode("cp932", $_) } @ARGV;
	return @fallback unless $HAS_WIN32_API && $n;
	my @w = eval {
		my $get = Win32::API->new("kernel32", "GetCommandLineW", "", "N") or die;
		my $len = Win32::API->new("kernel32", "lstrlenW", "N", "i") or die;
		my $p = $get->Call();
		split_cmdline(decode("UTF-16LE", unpack("P" . $len->Call($p) * 2, pack("J", $p))));
	};
	return @w >= $n ? @w[-$n .. -1] : @fallback;
}

if ($#ARGV < 0) {
	say "======================================================================";
	say " fix-mtime: ファイル更新日時修復ツール";
	say "======================================================================";
	if ($IS_WIN) {
		say " 対象のファイルやフォルダーをこのバッチファイルのアイコンに";
		say " ドラッグ＆ドロップして実行してください。";
		say "";
		say " コマンドラインから実行する場合:";
		say "   fix-mtime.bat \"対象フォルダーまたはファイル\" [...]";
	}
	else {
		say " 使い方:";
		say "   perl fix-mtime.pl 対象フォルダーまたはファイル [...]";
	}
	say "======================================================================";
	say "";
	exit 1;
}
for (get_wide_args()) {
	my $arg = $_;
	$arg =~ s/^\s+|\s+$//g;
	$arg =~ s/^"(.*)"$/$1/;
	procpath($arg) if length($arg);
}
if ($IS_WIN) {
	say "終了。Enter キーを押すと閉じます。";
	<STDIN>;
}
exit;

# フォルダーまたはファイルの処理
sub procpath
{
	my $path = shift or die;
	if (fm_islink($path)) {
		warn "シンボリックリンクはスキップします: $path\n";
		return;
	}
	if (fm_isdir($path)) {
		my $names = fm_readdir($path) or die "unable to open $path ($^E)";
		my $latest = 0;
		for my $name (@$names) {
			next if $name eq "." or $name eq "..";
			my $t = procpath("$path/$name");
			$latest = $t if $t && $t > $latest;
		}
		# 配下のファイルやフォルダーの最新の更新日にフォルダーの更新日を合わせる（空のフォルダーは変更しない）
		my $stat = fm_stat($path);
		if ($latest && $stat && $stat->{mtime} != $latest) {
			say($path);
			say("フォルダーの更新日を " . localtime($stat->{mtime})->datetime . " から " . localtime($latest)->datetime . " に変更します。");
			if (set_dir_mtime($path, $latest)) { $stat = fm_stat($path); }
			else { warn "フォルダーの更新日設定に失敗。\n"; }
			say "";
		}
		return $stat ? $stat->{mtime} : undef;
	}
	elsif (fm_isfile($path)) {
		procfile($path);
		my $stat = fm_stat($path);
		return $stat ? $stat->{mtime} : undef;
	}
	else { warn "no file or dir exists: $path\n"; }
	return;
}

# フォルダーの更新日（とアクセス日）を設定する。
# utimeL はフォルダーを開けないため、FILE_FLAG_BACKUP_SEMANTICS 付きで CreateFileW して SetFileTime する。
sub set_dir_mtime
{
	my ($path, $time) = @_;
	return fm_utime($time, $path) unless $HAS_WIN32_API;	# Linux 等ではフォルダーにも utime が使える
	my $ok = eval {
		my $create = Win32::API->new("kernel32", "CreateFileW", "PNNNNNN", "Q") or die;
		my $setft = Win32::API->new("kernel32", "SetFileTime", "QNPP", "N") or die;
		my $close = Win32::API->new("kernel32", "CloseHandle", "Q", "N") or die;
		my $wpath = encode("UTF-16LE", to_long_path($path)) . "\0\0";
		# FILE_WRITE_ATTRIBUTES, 共有=読み書き削除, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS
		my $h = $create->Call($wpath, 0x100, 7, 0, 3, 0x02000000, 0);
		return 0 if !$h || $h == ~0 || $h == -1;	# INVALID_HANDLE_VALUE
		my $v = ($time + 11644473600) * 10000000;
		my $ft = pack("VV", $v & 0xFFFFFFFF, $v >> 32);
		my $r = $setft->Call($h, 0, $ft, $ft);
		$close->Call($h);
		$r;
	};
	return $ok;
}

sub procfile
{
	my $path = shift;
	local $_ = $path;
	if (/\.(zip|epub|appx|msix|appxbundle|msixbundle|ipa|jar|iso|eml|msg|exe|msi|pdf|doc|xls|ppt|docx|xlsx|xlsm|pptx|pptm|ppsx|mp4|mkv|mov|wmv|avi|mp3|heic|jpe?g|png|gif|rm|rtf|flv|7z|rar|cab|lzh|lha|tar|tgz|tbz|txz|gz)$|\.tar\.(gz|bz2|xz)$|\.zip\.mp3$/i) {
		say($path);
		my $stat = fm_stat($path);
		if ($stat) {
			my $lastmod = $stat->{mtime};
			my $mtime;
			if (/\.(zip|epub|appx|msix|appxbundle|msixbundle|ipa|jar)$|\.zip\.mp3$/i) {
				$mtime = get_mtime_by_zip_members($path);
			}
			elsif (/\.(7z|rar|cab|lzh|lha|tar|tgz|tbz|txz|gz)$|\.tar\.(gz|bz2|xz)$/i) {
				if ($SEVEN_ZIP) {
					$mtime = get_mtime_by_7z($path);
				}
				else {
					say($IS_WIN
						? "7-Zip (C:\\Program Files\\7-Zip\\7z.exe) が見つからないためスキップします。"
						: "7-Zip (7zz / 7z / 7za / 7zr) が見つからないためスキップします。例: sudo apt install 7zip");
				}
			}
			elsif (/\.iso$/i) {
				$mtime = get_mtime_by_iso_image($path);
			}
			elsif (/\.eml$/i) {
				$mtime = get_mtime_by_eml($path);
			}
			elsif (/\.msg$/i) {
				$mtime = get_mtime_by_msg($path);
			}
			elsif (/\.(exe|msi)$/i) {
				$mtime = get_mtime_by_authenticode($path);
				if (!$mtime) {
					if (/\.exe$/i) {
						say(($IS_WIN ? "署名が見つからないため" : "Authenticode 署名の解析は Windows のみ対応のため") . "、自己展開型アーカイブとしての解析を試行します。");
					}
					else {
						say(($IS_WIN ? "署名が見つからないため" : "Authenticode 署名の解析は Windows のみ対応のため") . "、アーカイブとしての解析を試行します。");
					}
					if ($SEVEN_ZIP) {
						$mtime = get_mtime_by_7z($path);
					}
					if (!$mtime) {
						$mtime = get_mtime_by_zip_members($path);
					}
				}
			}
			else {
				$mtime = get_mtime_by_exiftool($path);
			}
			if ($mtime) {
				if ($mtime < Time::Piece->strptime("2000-01-01 00:00:00", "%Y-%m-%d %H:%M:%S")) {
					say("取得された更新日 " . localtime($mtime)->datetime . " が2000年未満のため、異常値と判断し無効とします。");
					$mtime = undef;
				}
				elsif ($mtime > time) {
					say("取得された更新日 " . localtime($mtime)->datetime . " が未来のため、異常値と判断し無効とします。");
					$mtime = undef;
				}
				elsif ($mtime == $lastmod) {
					say("取得された更新日 " . localtime($mtime)->datetime . " は実ファイルの更新日と一致しています。");
					$mtime = undef;
				}
				elsif ($mtime > $lastmod and $lastmod > 315500400) {
					say("取得された更新日 " . localtime($mtime)->datetime . " が実ファイルの更新日 " . localtime($lastmod)->datetime . " より新しいため、実ファイルの更新日を優先します。");
					$mtime = undef;
				}
				if ($mtime) {
					say("更新日を " . localtime($lastmod)->datetime . " から " . localtime($mtime)->datetime . " に変更します。");
					$lastmod = $mtime;
					fm_utime($lastmod, $path) or warn "更新日設定に失敗。";
				}
			}
			else {
				say("更新日は取得できませんでした。");
			}
		}
		else {
			warn "タイムスタンプが確認できなかったためスキップします。 $!"
		}
		say "";
	}
}

# PDF や Office ドキュメント、画像等、Image::ExifTool で確認できる最終更新日を得る
sub get_mtime_by_exiftool
{
	my $file = shift;
	my $mtime;
	eval {
		my $fh;
		fm_open(\$fh, '<', $file) or die "Cannot open $file: $!";
		my $ii = ImageInfo($fh) or die $!;
		close $fh;
		my $md;
		for my $val (
			$ii->{ModifyDate},
			$ii->{CreateDate},
			$ii->{MediaCreateDate},
			$ii->{TrackCreateDate},
			$ii->{DateCreated},
			$ii->{DateTimeOriginal},
			$ii->{DateUTC},
			$ii->{StatisticsWritingDateUTC},
			$ii->{StatisticsWritingDateUtc},
			$ii->{"StatisticsWritingDateUTC-eng"},
			$ii->{"StatisticsWritingDateUtc-eng"},
		) {
			if (defined $val && $val !~ /^\d{4}$/) {
				$md = $val;
				last;
			}
		}

		unless ($md) {
			# DateUTC や StatisticsWritingDateUTC のバリエーション（連番 (1) や言語サフィックス等）に対応
			for my $k (sort keys %$ii) {
				if ($k =~ /^(?:DateUTC|StatisticsWritingDateUTC)/i && defined $ii->{$k} && $ii->{$k} =~ /^\d{4}[:-]\d{2}[:-]\d{2}/) {
					$md = $ii->{$k};
					last;
				}
			}
		}

		# ほかの候補
		# TZ含む
		# CreationDate	タイムゾーン情報を含む作成日（iPhoneなどで重要）
		# DateTimeOriginal	撮影日時（静止画の規格に近い形式）
		# DateTimeDigitized	デジタル化された日時
		# TZ有無不明
		# EncodedDate
		unless ($md) {
			for (sort keys %{$ii}) {
				if (!/^File.*Date$/ && defined $ii->{$_} && $ii->{$_} =~ /20\d\d/) {
					say "$_: $ii->{$_}";
				}
			}
		}
		return unless $md;
		return if $md eq "0000:00:00 00:00:00";
		return if $md =~ m"^\d{4}$"; # 年のみの情報は無効
		$md =~ s"^(\d{4})[:-](\d{2})[:-](\d{2})"$1/$2/$3";
		if ($md =~ m"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$") {
			if ($file =~ /\.(doc|xls|ppt|mp4|mkv|mov)$/i) {
				# どうも旧 Office と MP4/MKV/MOV は Z がなくても GMT の模様
				$md .= "Z";
			}
			else {
				# それ以外のタイムゾーンなしは JST とみなす
				$md .= "+09:00";
			}
		}
		$mtime = str2time($md);
		die "予期せぬ ModifyDate or DateCreated* 書式です: $md" unless $mtime;
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# ZIP ファイル中の最新のファイルの最終更新日を得る
sub get_mtime_by_zip_members
{
	my $file = shift;
	my $mtime;
	eval {
		my $fh;
		fm_open(\$fh, '<', $file) or die "Cannot open $file: $!";
		local $SIG{__WARN__} = sub {};
		my $zip = Archive::Zip->new($fh);
		close $fh;
		if ($zip) {
			my @members = $zip->members;
			my $maxtime = 0;
			my $member;
			foreach $member (@members) {
				if ($member->lastModTime() > $maxtime) { $maxtime = $member->lastModTime(); }
			}
			$mtime = $maxtime if $maxtime > 0;
		}
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# ISO ファイルのメタデータの最終更新日を得る
sub get_mtime_by_iso_image
{
	my $file = shift;
	my $mtime;
	my $buf;
	eval {
		my $fh;
		fm_open(\$fh, '<:raw', $file) or die "Cannot open $file: $!";
		seek $fh, 2048 * 16 + 1, 0 or die "can't seek $file";
		read $fh, $buf, 5 or die "can't read $file";
		die "not ISO9660 image: $file" unless $buf eq "CD001";
		seek $fh, 2048 * 16 + 813, 0 or die "can't seek $file";
		read $fh, $buf, 17 or die "can't read $file";
		close $fh;

	};
	if ($@) { warn $@; return; }
	my ($year, $mon, $day, $hour, $min, $sec, $dev) = ($buf =~ /^(....)(..)(..)(..)(..)(..)..(.)/);
	$dev = unpack "c", $dev;
	eval {
		$mtime = timegm($sec, $min, $hour, $day, $mon - 1, $year) - $dev * 15 * 60;
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# EML ファイル中の最新の Received ヘッダーまたは Date ヘッダーの日時を得る
sub get_mtime_by_eml
{
	my $file = shift;
	my $mtime;
	eval {
		my $header = '';
		my $fh;
		fm_open(\$fh, '<', $file) or die "Cannot open $file: $!";
		while (my $line = <$fh>) {
			$line =~ s/\x0D\x0A|\x0D|\x0A/\n/;
			last if $line =~ /^\s*$/;  # ヘッダー終了
			$header .= $line;
		}
		close $fh;
		$header =~ s/\s*\n\s+/ /g; # 継続行を結合
		for (split "\n", $header) {
			if (/^Received:.*;\s*(.+?)\s*$/i) {
				$mtime = str2time($1);
				last if $mtime;
			}
			if (/^Date:\s*(.+?)\s*$/i) {
				$mtime = str2time($1);
				last if $mtime;
			}
		}
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# 7-Zip を使用してアーカイブ内の最新のファイルの最終更新日を得る
sub get_mtime_by_7z
{
	my $file = shift;
	my $mtime;
	eval {
		my $long_file = to_long_path($file);
		# 圧縮された tar (tar.gz / tar.bz2 / tar.xz / tgz / tbz / txz) は、そのまま一覧すると tar 1 個としか見えない。
		# そのため 1 個目の 7z で展開して標準出力に流し、2 個目の 7z で tar の中身（メンバー）を一覧する。
		my $nested = $file =~ /\.(tgz|tbz|txz)$|\.tar\.(gz|bz2|xz)$/i;
		my $cmd;
		if (!$IS_WIN) {
			# シェルを経由するため、パスは単一引用符で囲んで UTF-8 のバイト列で渡す
			my $quote = sub { my $s = shift; $s =~ s/'/'\\''/g; "'$s'" };
			my $z = $quote->($SEVEN_ZIP);
			my $path = $quote->(native_path($long_file));
			$cmd = $nested
				? "$z x -so -- $path 2>/dev/null | $z l -slt -ttar -si -sccUTF-8 2>/dev/null"
				: "$z l -slt -sccUTF-8 -- $path 2>/dev/null";
		}
		elsif (is_cp932_safe($long_file . $SEVEN_ZIP)) {
			my $enc_file = encode("cp932", $long_file);
			$cmd = $nested
				? qq{"$SEVEN_ZIP" x -so "$enc_file" 2>nul | "$SEVEN_ZIP" l -slt -ttar -si -sccUTF-8 2>nul}
				: qq{"$SEVEN_ZIP" l -slt -sccUTF-8 "$enc_file" 2>nul};
		}
		else {
			# cp932 で表せない文字を含むパスはコマンドラインで渡せないため、
			# 引数を UTF-16 で渡せる PowerShell 経由で実行する（パスは環境変数に Base64 で格納）
			# tar のパイプは PowerShell 内では扱えない（バイナリが壊れる）ため、cmd.exe に任せる
			$ENV{FIX_MTIME_TARGET_FILE_B64} = encode_base64(encode("UTF-8", $long_file), "");
			$ENV{FIX_MTIME_7Z_B64} = encode_base64(encode("UTF-8", $SEVEN_ZIP), "");
			$ENV{FIX_MTIME_NESTED} = $nested ? "1" : "0";
			my $script = <<'PS';
$u = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $u
$f = $u.GetString([Convert]::FromBase64String($env:FIX_MTIME_TARGET_FILE_B64))
$z = $u.GetString([Convert]::FromBase64String($env:FIX_MTIME_7Z_B64))
if ($env:FIX_MTIME_NESTED -eq '1') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/s /c ""' + $z + '" x -so "' + $f + '" 2>nul | "' + $z + '" l -slt -ttar -si -sccUTF-8 2>nul"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $u
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
} else {
    & $z l -slt -sccUTF-8 $f 2>$null
}
PS
			my $enc_script = encode_base64(encode("UTF-16LE", $script), "");
			$cmd = qq{powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc_script 2>nul};
		}
		my $pid = open(my $fh, "-|", $cmd);
		unless ($pid) {
			die "7z コマンドの実行に失敗しました: $!";
		}
		binmode $fh, ":encoding(utf8)";
		my $in_files = 0;
		my $maxtime = 0;
		while (my $line = <$fh>) {
			$line =~ s/[\r\n]+$//;
			if ($line =~ /^----------/) {
				$in_files = 1;
				next;
			}
			if ($in_files && $line =~ /^Modified\s*=\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/) {
				my $t = str2time($1);
				if ($t && $t > $maxtime) {
					$maxtime = $t;
				}
			}
		}
		close $fh;
		$mtime = $maxtime if $maxtime > 0;
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# MSG (Outlookアイテム) ファイル中の受信日時または送信日時を得る
sub get_mtime_by_msg
{
	my $file = shift;
	my $mtime;
	eval {
		my $fh;
		fm_open(\$fh, '<:raw', $file) or die "Cannot open $file: $!";
		my $content;
		{
			local $/;
			$content = <$fh>;
		}
		close $fh;

		# OLE2 (Compound File Binary Format) マジックナンバー確認
		return unless substr($content, 0, 8) eq "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1";

		# 探索する MAPI プロパティタグ (型: PtypTime = 0x0040)
		# 0x0E06 = PidTagMessageDeliveryTime (受信日時・最優先)
		# 0x0039 = PidTagClientSubmitTime    (送信日時)
		# 0x3007 = PidTagCreationTime        (作成日時)
		# 0x3008 = PidTagLastModificationTime (変更日時)
		my @target_tags = (
			pack("vv", 0x0040, 0x0E06),
			pack("vv", 0x0040, 0x0039),
			pack("vv", 0x0040, 0x3007),
			pack("vv", 0x0040, 0x3008),
		);

		my $now = time;
		my $min_time = 946684800; # 2000-01-01

		for my $tag (@target_tags) {
			my $pos = 0;
			while (($pos = index($content, $tag, $pos)) != -1) {
				if ($pos + 16 <= length($content)) {
					my ($low, $high) = unpack("VV", substr($content, $pos + 8, 8));
					unless ($low == 0 && $high == 0) {
						my $val = ($high * 4294967296.0 + $low) / 10000000.0 - 11644473600;
						my $t = int($val + 0.5);
						if ($t >= $min_time && $t <= $now) {
							$mtime = $t;
							last;
						}
					}
				}
				$pos += 4;
			}
			last if $mtime;
		}
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}

# EXE や MSI のデジタル署名（Authenticode タイムスタンプまたは署名日時）を得る（Windows のみ対応）
sub get_mtime_by_authenticode
{
	return undef unless $IS_WIN;
	my $file = shift;
	my $mtime;
	eval {
		my $ps_script = "$FindBin::Bin/fix-mtime-authenticode.ps1";
		unless (-f $ps_script) {
			die "PowerShellスクリプトが見つかりません: $ps_script";
		}

		my $long_file = to_long_path($file);
		
		# 環境変数経由で渡すことでコマンドライン文字数制限やエスケープ不具合を回避
		# CP932 範囲外の文字を保持するため UTF-8 を Base64 化して渡す
		local $ENV{FIX_MTIME_TARGET_FILE_B64} = encode_base64(encode("UTF-8", $long_file), "");
		my $cmd = qq{powershell -NoProfile -ExecutionPolicy Bypass -File "$ps_script"};
		my $out = `$cmd`;
		if ($out) {
			$out =~ s/[\r\n]+$//;
			if ($out =~ m"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})") {
				$mtime = str2time($1);
			}
		}
	};
	if ($@) {
		say("ERROR: $@");
	}
	return $mtime;
}