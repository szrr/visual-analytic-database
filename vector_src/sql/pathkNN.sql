select video_name
from dataset_video
where kNN(VIDEO_EXTRACTION(path"/home/szr/subquery/video_process/test_video/6578103253609745667.mp4"), d_feature) <= 5
;