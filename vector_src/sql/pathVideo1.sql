select video_name, VIDEO_SIMILARITY(VIDEO_EXTRACTION(path"/home/szr/subquery/gtvideos/6547319806729653518.mp4"), d_feature) as score
from dataset_video
where video_name in (
    select video_name
    from dataset_video
    where kNN(VIDEO_EXTRACTION(path"/home/szr/subquery/gtvideos/6547319806729653518.mp4"), d_feature) <= 5
)
group by video_name
;