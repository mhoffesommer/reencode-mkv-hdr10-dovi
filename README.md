# reencode-mkv-hdr10-dovi
Batch-reencodes a folder of video files to a given quality level based on filename; retains HDR10/HDR10+/DoVi. 

All english/german audio tracks and subtitles are copied directly, everything else is stripped.

Just drop the script into a folder containing a bunch of video files and run
it. All contained TS/MKV/MP4/AVI/M2TS files will be converted into MKV and 
written into the same folder with ".rnc" added at the end of the filename.

This bash script needs:
- ffmpeg
- ffprobe
- dovi_tool
- hdr10plus_tool
- jq
- mkvmerge

For files less than 4K:

| Filename contains... | Quality level |
| -------------------- | ------------- |
| .hq.                 | slow, CRF22   |
| remux                | medium, CRF22 |
|                      | faster, CRF22 |

For 4K files:

| Filename contains... | Quality level |
| -------------------- | ------------- |
| .grain. & .hq.       | slow, CRF20   |
| .grain. & remux      | medium, CRF21 |
| .grain.              | medium, CRF22 |
| .hq.                 | slow, CRF20   |
| remux                | slow, CRF22   |
|                      | medium, CRF22 |

If the filename contains ".grain." the libx265 grain tune parameter will be used.

Note: TS files will be deinterlaced using the yadif filter.
