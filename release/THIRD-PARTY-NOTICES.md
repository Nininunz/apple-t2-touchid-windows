# Third-party components

The project retains Osaul4ik's original LICENSE and NOTICE, included beside this file. The upstream v0.9 engine adapter and runtime DLLs are reused without modification; release.json records their hashes and archive provenance. Fork PE files are rebuilt from the recorded source revision.

libplist 2.8.0: https://github.com/libimobiledevice/libplist/tree/fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4

The included libplist runtime DLLs originate from upstream's v0.9 release. The exported runtime version reports 2.8.0; the release build uses the corresponding public headers. COPYING and COPYING.LESSER from that source revision are included in licenses/libplist. Refer to the source repository and these texts for copyright, license terms and source. These original runtime binaries were not rebuilt for this fork; an exact reproducible build of them is not claimed.

The GUI targets Microsoft's .NET 8 Windows Desktop runtime, installed separately. Windows driver frameworks and system libraries are supplied by Windows and are not redistributed here.
