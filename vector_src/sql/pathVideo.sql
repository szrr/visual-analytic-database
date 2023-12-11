select video_name, VIDEO_SIMILARITY(VIDEO_EXTRACTION(path"/home/szr/SVDexperiment/gtVideos/6578103253609745667.mp4"), d_feature) as score
from (
    select video_name, d_feature
    from dataset_video
    where video_name in (
        select video_name
        from dataset_video
        where kNN(VIDEO_EXTRACTION(path"/home/szr/subquery/video_process/test_video/6578103253609745667.mp4"), d_feature) <= 5
    )
) candidate_dataset_video
group by video_name
order by score
;

