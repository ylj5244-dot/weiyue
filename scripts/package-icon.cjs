const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..', 'build');
const types = [[16,'icp4'],[32,'icp5'],[128,'ic07'],[256,'ic08'],[512,'ic09']];
const blocks = types.map(([size,type]) => {
  const png = fs.readFileSync(path.join(root,'AppIcon.iconset',`icon_${size}x${size}.png`));
  const header = Buffer.alloc(8); header.write(type); header.writeUInt32BE(png.length + 8,4);
  return Buffer.concat([header,png]);
});
const png = fs.readFileSync(path.join(root,'AppIcon.iconset','icon_512x512@2x.png'));
const h = Buffer.alloc(8); h.write('ic10'); h.writeUInt32BE(png.length+8,4); blocks.push(Buffer.concat([h,png]));
const header=Buffer.alloc(8); header.write('icns'); header.writeUInt32BE(8+blocks.reduce((n,b)=>n+b.length,0),4);
fs.writeFileSync(path.join(root,'AppIcon.icns'),Buffer.concat([header,...blocks]));
