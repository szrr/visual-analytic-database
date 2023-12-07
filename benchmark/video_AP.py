import sys

def get_labels_for_video(video_name, label_file_path='positive_labels'):
    with open(label_file_path, 'r') as file:
        lines = file.readlines()
    labels = [line.strip().split()[1] for line in lines if line.strip().split()[0] == video_name]
    return labels

def get_video_position_from_pred(video_name, pred_file_path='video_pred.txt'):
    with open(pred_file_path, 'r') as file:
        lines = file.readlines()
    lines = lines[::-1]  # Reverse the order to get high scores first
    videos = [line.strip().split()[0] for line in lines]
    scores = [float(line.strip().split()[1]) for line in lines]
    sorted_indexes = sorted(range(len(scores)), key=lambda k: scores[k], reverse=True)
    if video_name not in videos:
        return -1
    return sorted_indexes.index(videos.index(video_name))

def calculate_mAP_for_video(video_name):
    mAP = 0
    
    labels = get_labels_for_video(video_name)
    # print(labels)
    labels.append(video_name)  # add video itself
    with open('video_pred.txt', 'r') as file:
        lines = file.readlines()
    lines = lines[::-1]  # Reverse the order to get high scores first
    videos = [line.strip().split()[0] for line in lines]
    # print(videos)
    relevant_retrievals = 0
    sum_precisions = 0
    for idx, video in enumerate(videos):
        if video in labels:
            relevant_retrievals += 1
            sum_precisions += relevant_retrievals / (idx + 1)
    mAP = sum_precisions / len(labels) if labels else 0
    return mAP

def main(video_index):
    with open('search_videos.txt', 'r') as file:
        lines = file.readlines()
    video_name = lines[int(video_index)].strip()
    print(video_name)
    mAP = calculate_mAP_for_video(video_name)
    # print(mAP)
    position = get_video_position_from_pred(video_name)
    # print(position)
    labels = get_labels_for_video(video_name)
    labels.insert(0, video_name)
    with open('AP.txt', 'a') as file:
        file.write(f'\n{video_name} {mAP} ')
        for label in labels:
            file.write(f'{label} {get_video_position_from_pred(label)} ')

if __name__ == "__main__":
    video_index = sys.argv[1]
    main(video_index)