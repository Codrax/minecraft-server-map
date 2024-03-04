unit LibDefine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, IdSSLOpenSSLHeaders;

var
  RootFolder: string;
  LibFolder: string;
  RuntimeFolder: string;

implementation


initialization
  RootFolder := ExtractFileDir(ParamStr(0)); // Get exe location

  if RootFolder = '/usr/bin' then
    begin
      LibFolder := '/usr/lib/ibroadcast/';
      RuntimeFolder := '/usr/share/ibroadcast/';
    end
else
  begin
    // Folders
    LibFolder := RootFolder + '/shared-lib/';
    RuntimeFolder := RootFolder + '/runtime/';
  end;

  // Libs
  IdOpenSSLSetLibPath( LibFolder );
end.

