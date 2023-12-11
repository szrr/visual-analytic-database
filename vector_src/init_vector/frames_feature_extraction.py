import os
import torch
import torch.nn as nn
import torch.nn.parallel
import torch.backends.cudnn as cudnn
import torch.distributed as dist
import torch.optim
import torch.multiprocessing as mp
import torch.utils.data
import torch.utils.data.distributed
import torchvision.transforms as transforms
import torchvision.datasets as datasets
import torchvision.models as models
import numpy as np
import cv2
import sys

if __name__ == '__main__':
    # load image path
    content = sys.argv[1]
    vec_save_path = sys.argv[2]
    # print("image path: " + content)

    # set model = resnet50
    model = models.resnet50()

    # freeze all layers
    for name, param in model.named_parameters():
        param.requires_grad = False

    # obtain pretrained parameters
    path = "/home/szr/scp/param/checkpoint_SVD_100segments_0099.pth.tar"
    # print("=> loading checkpoint '{}'".format(path))
    checkpoint = torch.load(path, map_location="cpu")
    state_dict = checkpoint['state_dict']
    fc_state_dict = {k: v for k, v in state_dict.items() if k.startswith('module.encoder.fc')}
    new_fc_state_dict = {}
    for k, v in fc_state_dict.items():
        name = k[18:]  # remove `module.` prefix
        new_fc_state_dict[name] = v
    for k in list(state_dict.keys()):
        # retain only encoder up to before the embedding layer
        if k.startswith('module.encoder') and not k.startswith('module.encoder.fc'):
            # remove prefix
            state_dict[k[len("module.encoder."):]] = state_dict[k]
        # delete renamed or unused k
        del state_dict[k]
    msg = model.load_state_dict(state_dict, strict=False)
    print(msg)
    assert set(msg.missing_keys) == {"fc.weight", "fc.bias"}
    print("=> loaded pre-trained model '{}'".format(path))
    # delete fc layer
    # classifier = nn.Sequential()
    # model.fc = classifier
    # Change the device to GPU

    fc_layer = nn.Sequential(
        nn.Linear(in_features=2048, out_features=2048, bias=False),
        nn.BatchNorm1d(2048, eps=1e-05, momentum=0.1, affine=True, track_running_stats=True),
        nn.ReLU(inplace=True),
        nn.Linear(in_features=2048, out_features=2048, bias=False),
        nn.BatchNorm1d(2048, eps=1e-05, momentum=0.1, affine=True, track_running_stats=True),
        nn.ReLU(inplace=True),
        nn.Linear(in_features=2048, out_features=128, bias=True),
        nn.BatchNorm1d(128, eps=1e-05, momentum=0.1, affine=False, track_running_stats=True)
    )
    model.fc = fc_layer
    
    # print(new_fc_state_dict)
    msg = model.fc.load_state_dict(new_fc_state_dict)
    print(msg)

    # Change the device to GPU
    device = torch.device('cuda:1' if torch.cuda.is_available() else "cpu")
    model = model.to(device)

    # image normalization
    normalize = transforms.Normalize(mean=[0.485, 0.456, 0.406],
                                        std=[0.229, 0.224, 0.225])
    transform = transforms.Compose([
        transforms.ToPILImage(),
        transforms.Resize(256),
        transforms.CenterCrop(224),
        transforms.ToTensor(),
        normalize,
    ])

    features = []


    img = cv2.imread(str(content))
    img = transform(img)
    img = torch.unsqueeze(img, 0)
    img = img.to(device)
    # We only extract features, so we don't need gradient
    with torch.no_grad():
    # Extract the feature from the image
        feature = model(img)
    # Convert to NumPy Array, Reshape it, and save it to features variable
    features = (feature.cpu().detach().numpy().reshape(-1))
    features.tofile(str(vec_save_path))