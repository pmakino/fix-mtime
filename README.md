# fix-mtime

コピーやダウンロードで変わってしまったファイルの更新日時を、ファイル自身に埋め込まれた日時情報を参照して復元するツールです。Windows と Linux で動作します。

Windows ではフォルダーやファイルをバッチファイルにドラッグ&ドロップするだけで、Linux ではコマンドラインから、配下を再帰的に処理します。ファイルだけでなく、フォルダーの更新日時も配下の最新のものに合わせます。

## 何をするか

ファイルの種類ごとに、次の情報から「本来の更新日時」を取得し、実ファイルの更新日時を書き換えます。

| 種類 | 日時の取得元 |
|---|---|
| zip / epub / appx / msix / appxbundle / msixbundle / ipa / jar / `.zip.mp3` | 中身のメンバーの最新更新日時 |
| 7z / rar / cab / lzh / lha / tar / gz | 7-Zip で一覧した中身の最新更新日時 |
| tar.gz / tar.bz2 / tar.xz / tgz / tbz / txz | 7-Zip で展開して tar の中身(ファイルとフォルダー)を一覧し、その最新更新日時 |
| iso | ISO9660 のボリューム更新日時 |
| eml | 最初の `Received` ヘッダー、なければ `Date` ヘッダー |
| msg | 受信日時、送信日時、作成日時、変更日時の順(MAPI プロパティ) |
| exe / msi | Authenticode の署名タイムスタンプ(Windows のみ)。署名がない場合や Linux では、自己展開アーカイブとして解析 |
| pdf / doc / xls / ppt / docx / xlsx / xlsm / pptx / pptm / ppsx / rtf / 画像 / 動画 / mp3 など | Image::ExifTool で読めるメタデータ(ModifyDate、CreateDate、DateTimeOriginal など) |

### 取得した日時を採用しない場合

次のいずれかに当てはまる場合は、異常値と判断して書き換えません。

- 2000 年より前の日時
- 未来の日時
- すでに実ファイルの更新日時と一致している
- 実ファイルの更新日時より新しい(この場合は実ファイルの日時を優先)

### フォルダーの更新日時

配下のファイルやフォルダーを処理したあと、フォルダーの更新日時を配下で最新のものに合わせます。深い階層から順に処理するので、結果は上位のフォルダーまで伝わります。空のフォルダーは変更しません。

## 必要なもの

### 共通

- Perl 5.10 以上
  - HTTP::Date
  - Image::ExifTool(`lib` フォルダーにスクリプトと同じ階層で置くこともできます)
  - そのほか(Archive::Zip、Time::Piece など)は Perl のコアモジュールです。
- 7-Zip(7z、rar などのアーカイブを処理する場合)

足りないモジュールがあると、実行時にインストール方法が表示されます。

### Windows

- Windows 10 / 11、Strawberry Perl を想定
  - Win32::LongPath
  - Win32::API(推奨。フォルダーの更新日時の設定と、CP932 範囲外の文字の対応に使います。Strawberry Perl には同梱されています)
- 7-Zip は `C:\Program Files\7-Zip\7z.exe`、`C:\Program Files (x86)\7-Zip\7z.exe`、または `PATH` 上の `7z` を探します。
- PowerShell(exe / msi の署名を読む場合。Windows に標準で入っています)

### Linux

- 7-Zip は `PATH` 上の `7zz`、`7z`、`7za`、`7zr` の順に探します。
- Debian / Ubuntu の例:

```sh
sudo apt install libhttp-date-perl libimage-exiftool-perl 7zip
```

## 使い方

### Windows: ドラッグ&ドロップ

対象のファイルまたはフォルダーを `fix-mtime.bat` のアイコンにドロップします。

### Windows: コマンドライン

```bat
fix-mtime.bat "対象フォルダーまたはファイル" [...]
```

処理が終わると「Enter キーを押すと閉じます」と表示されるので、結果を確認してから閉じてください。

### Linux

```sh
perl fix-mtime.pl 対象フォルダーまたはファイル [...]
```

## ファイル構成

| ファイル | 役割 |
|---|---|
| `fix-mtime.bat` | Windows 用の起動用バッチファイル |
| `fix-mtime.pl` | 本体 |
| `fix-mtime-authenticode.ps1` | exe / msi のデジタル署名から日時を取り出す補助スクリプト(Windows のみ) |

## 注意

- **ファイルの更新日時を実際に書き換えます**。重要なファイルは、事前にバックアップを取ってから試してください。
- 日時にタイムゾーンが付いていない場合は、doc / xls / ppt / mp4 / mkv / mov は GMT、それ以外は JST(+09:00)とみなします。
- Windows では、260 文字を超えるパスや、CP932 範囲外の文字(ハングルなど)を含むパスにも対応しています。ログを UTF-8 で表示するため、実行中だけコンソールのコードページを 65001 に切り替え、終了時に元へ戻します。Win32::API が使えない場合やリダイレクト時は CP932 で出力し、範囲外の文字は `?` で表示します。
- Linux では、ファイル名とログを UTF-8 として扱います。UTF-8 として解釈できない名前のファイルやフォルダーはスキップします。シンボリックリンクもスキップします。

## ライセンス

[MIT License](LICENSE)
