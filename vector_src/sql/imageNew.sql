select d_frame_id, DISTANCE(d_feature, EXTRACTION(path"/home/szr/frames.png")) as dis
from DATASET_VIDEO
order by dis
limit 50
;