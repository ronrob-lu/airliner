import os
from PIL import Image, ImageDraw

def create_airliner_texture(filepath):
    # Create a 64x64 texture for the airliner body
    # Simple white/gray fuselage with colored accents
    img = Image.new('RGBA', (64, 64), (255, 255, 255, 255))
    draw = ImageDraw.Draw(img)
    # Add a gray underbelly
    draw.rectangle([0, 32, 64, 64], fill=(200, 200, 200, 255))
    # Add a blue stripe along the side
    draw.rectangle([0, 28, 64, 32], fill=(0, 0, 150, 255))
    # Add some windows
    for x in range(4, 60, 8):
        draw.rectangle([x, 20, x+4, 24], fill=(100, 100, 100, 255))
    img.save(filepath)

def create_item_texture(filepath):
    # Create a 16x16 icon for the inventory item
    img = Image.new('RGBA', (16, 16), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Draw a simple plane shape
    draw.polygon([(2, 8), (14, 8), (12, 10), (2, 10)], fill=(255, 255, 255, 255))
    draw.polygon([(6, 10), (8, 14), (10, 10)], fill=(0, 0, 150, 255))
    draw.polygon([(12, 6), (14, 8), (12, 8)], fill=(0, 0, 150, 255))
    img.save(filepath)

def create_waypoint_texture(filepath):
    # Create a 16x16 texture for the waypoint block
    img = Image.new('RGBA', (16, 16), (50, 50, 50, 255))
    draw = ImageDraw.Draw(img)
    # Draw a bright glowing center
    draw.rectangle([4, 4, 11, 11], fill=(255, 0, 0, 255))
    draw.rectangle([6, 6, 9, 9], fill=(255, 255, 0, 255))
    img.save(filepath)

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.abspath(__file__))
    textures_dir = os.path.join(base_dir, 'textures')
    if not os.path.exists(textures_dir):
        os.makedirs(textures_dir)

    create_airliner_texture(os.path.join(textures_dir, 'airliner.png'))
    create_item_texture(os.path.join(textures_dir, 'airliner_item.png'))
    create_waypoint_texture(os.path.join(textures_dir, 'airliner_waypoint.png'))
    print("Textures generated successfully.")
