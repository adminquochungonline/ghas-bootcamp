// Chạy "vue-cli-service build" bằng API rồi thoát tường minh.
// - Bỏ qua plugin eslint: source có lỗi ESLint cố ý (no-unused-vars) phục vụ lab GHAS.
// - Với bộ dependency hiện tại, tiến trình build không tự thoát sau khi xong (worker MessagePort
//   còn treo), làm docker build / az acr build bị treo. Gọi process.exit để kết thúc.
const Service = require('@vue/cli-service/lib/Service')

const service = new Service(process.cwd())
service
  .run('build', { _: [], 'skip-plugins': '@vue/cli-plugin-eslint' }, [])
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
