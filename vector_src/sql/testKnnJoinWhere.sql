select video_name, DISTANCE(v_feature, f_feature)
from video kNN(k=5) join frames on v_feature = f_feature
where DISTANCE(v_feature, f_feature) < 0.5
;