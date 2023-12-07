import os
import sys
import subprocess

# how to use
# python3 find_two_video.py video_name1 video_name2
# e.g. python3 find_two_video.py 6578103253609745667.mp4 6578057607393578247.mp4

def main():
    print('parameter num =', len(sys.argv))
    print('fileName :', sys.argv[0])
    for i in range(1, len(sys.argv)):
        print('videoName[%s] = %s' % (i, sys.argv[i]))
    for dirpath, dirnames, filenames in os.walk('/mnt/data1/svddataset/videos'):
        for filename in filenames:
            if(filename == sys.argv[1] or filename == sys.argv[2]):
                path = os.path.join(dirpath, filename)
                print(path)

if __name__ == "__main__":
    main()
